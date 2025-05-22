#!/bin/bash
# BGP Mesh Network Implementation Script
# This script sets up a WireGuard mesh network between BGP speakers and configures iBGP

# Exit on any error
set -e

# Load environment variables
source .env

# Log file setup
LOG_FILE="mesh_network_$(date +%Y%m%d_%H%M%S).log"
echo "Starting mesh network setup at $(date)" > "$LOG_FILE"

# Log function
log() {
  local message="$1"
  local level="${2:-INFO}"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  
  echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
  echo "[$level] $message"
}

# Define BGP speaker details based on Vultr API data
declare -A PUBLIC_IPS=(
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
  ["lax"]="149.248.2.74"
)

declare -A RESERVED_IPS=(
  ["ewr"]="64.176.197.138"
  ["mia"]="144.202.39.66"
  ["ord"]="149.28.121.119"
  ["lax"]="45.76.76.125"
)

declare -A IPV6_IPS=(
  ["ewr"]="2001:19f0:0000:78bb:5400:05ff:fe65:af39"
  ["mia"]="2001:19f0:9000:2669:5400:05ff:fe65:af41"
  ["ord"]="2001:19f0:5c01:058c:5400:05ff:fe65:af4a"
  ["lax"]="2001:19f0:6000:3b6a:5400:05ff:fe65:af4e"
)

declare -A SERVER_ROLES=(
  ["lax"]="primary"
  ["ord"]="secondary" # Chicago - closest to LA
  ["mia"]="tertiary"  # Miami - farther from LA
  ["ewr"]="quaternary" # Newark - farthest from LA
)

# WireGuard subnet and port
WG_SUBNET="10.10.10.0/24"
WG_PORT=51820

# Function to install WireGuard on a server
install_wireguard() {
  local server=$1
  local ip=${PUBLIC_IPS[$server]}
  
  log "Installing WireGuard on $server ($ip)..."
  
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "root@$ip" "
    apt-get update
    apt-get install -y wireguard wireguard-tools
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
    sysctl -p
    
    # Create WireGuard keys directory
    mkdir -p /etc/wireguard/keys
    chmod 700 /etc/wireguard/keys
  "
  
  log "WireGuard installed on $server"
}

# Function to generate WireGuard keys
generate_wireguard_keys() {
  local server=$1
  local ip=${PUBLIC_IPS[$server]}
  
  log "Generating WireGuard keys for $server..."
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Generate private and public keys
    wg genkey | tee /etc/wireguard/keys/${server}_private.key | wg pubkey > /etc/wireguard/keys/${server}_public.key
    chmod 600 /etc/wireguard/keys/${server}_private.key
  "
  
  # Get the public key
  local pubkey=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "cat /etc/wireguard/keys/${server}_public.key")
  
  # Store in local array
  PUBLIC_KEYS[$server]=$pubkey
  
  log "Generated WireGuard keys for $server (Public key: ${pubkey:0:8}...)"
}

# Function to create WireGuard configuration
create_wireguard_config() {
  local server=$1
  local ip=${PUBLIC_IPS[$server]}
  local wg_ip="10.10.10.$2/24"
  
  log "Creating WireGuard configuration for $server ($wg_ip)..."
  
  # Generate the configuration
  local config="[Interface]\n"
  config+="PrivateKey = \$(cat /etc/wireguard/keys/${server}_private.key)\n"
  config+="Address = $wg_ip\n"
  config+="ListenPort = $WG_PORT\n\n"
  
  # Add peers (all other servers)
  for peer in "${!PUBLIC_IPS[@]}"; do
    if [ "$server" != "$peer" ]; then
      local peer_id=${SERVER_IDS[$peer]}
      local peer_ip="10.10.10.$peer_id/32"
      local peer_pubkey=${PUBLIC_KEYS[$peer]}
      local peer_endpoint=${PUBLIC_IPS[$peer]}
      
      config+="[Peer]\n"
      config+="PublicKey = $peer_pubkey\n"
      config+="AllowedIPs = $peer_ip\n"
      config+="Endpoint = $peer_endpoint:$WG_PORT\n"
      config+="PersistentKeepalive = 25\n\n"
    fi
  done
  
  # Deploy config to server
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    echo -e \"$config\" > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    
    # Allow WireGuard traffic in firewall
    if command -v ufw &> /dev/null; then
      ufw allow $WG_PORT/udp
      ufw route allow in on wg0 out on eth0
      ufw reload
    else
      iptables -A INPUT -p udp --dport $WG_PORT -j ACCEPT
      iptables -A FORWARD -i wg0 -j ACCEPT
      iptables -A FORWARD -o wg0 -j ACCEPT
      iptables-save > /etc/iptables/rules.v4
    fi
    
    # Enable and start WireGuard
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
  "
  
  log "WireGuard configuration created and service started on $server"
}

# Function to configure iBGP
configure_ibgp() {
  local server=$1
  local ip=${PUBLIC_IPS[$server]}
  local is_route_reflector=0
  
  # LAX (Los Angeles) will be our route reflector since it's the primary node
  # This makes sense geographically as the company is headquartered in LA
  if [ "$server" == "lax" ]; then
    is_route_reflector=1
  fi
  
  log "Configuring iBGP on $server (Route Reflector: $is_route_reflector)..."
  
  # Generate iBGP configuration
  local ibgp_config="# iBGP Configuration for mesh network\n\n"
  
  if [ $is_route_reflector -eq 1 ]; then
    # Route reflector configuration
    ibgp_config+="# Route Reflector Configuration\n"
    ibgp_config+="define rr_cluster_id = 1;\n\n"
    
    # Create peer template for route reflection
    ibgp_config+="template bgp ibgp_clients {\n"
    ibgp_config+="  local as ${OUR_AS};\n"
    ibgp_config+="  rr client;\n"
    ibgp_config+="  rr cluster id rr_cluster_id;\n"
    ibgp_config+="  next hop self;\n"
    ibgp_config+="  direct;\n"
    ibgp_config+="  igp table master;\n"
    ibgp_config+="  import all;\n"
    ibgp_config+="  export all;\n"
    ibgp_config+="}\n\n"
    
    # Create iBGP peers (route clients)
    for peer in "${!PUBLIC_IPS[@]}"; do
      if [ "$server" != "$peer" ]; then
        local peer_id=${SERVER_IDS[$peer]}
        local peer_wg_ip="10.10.10.$peer_id"
        
        ibgp_config+="protocol bgp ibgp_${peer} from ibgp_clients {\n"
        ibgp_config+="  neighbor $peer_wg_ip as ${OUR_AS};\n"
        ibgp_config+="  description \"iBGP to ${peer} (${SERVER_ROLES[$peer]})\";\n"
        ibgp_config+="}\n\n"
      fi
    done
  else
    # Non-route-reflector configuration (client)
    ibgp_config+="# iBGP Client Configuration\n"
    ibgp_config+="protocol bgp ibgp_rr {\n"
    ibgp_config+="  local as ${OUR_AS};\n"
    ibgp_config+="  neighbor 10.10.10.${SERVER_IDS[\"lax\"]} as ${OUR_AS};\n"
    ibgp_config+="  next hop self;\n"
    ibgp_config+="  direct;\n"
    ibgp_config+="  igp table master;\n"
    ibgp_config+="  import all;\n"
    ibgp_config+="  export all;\n"
    ibgp_config+="  description \"iBGP to Route Reflector (LAX)\";\n"
    ibgp_config+="}\n\n"
  fi
  
  # Deploy iBGP configuration to server
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    echo -e \"$ibgp_config\" > /etc/bird/ibgp.conf
    
    # Add include statement if not already present
    if ! grep -q 'include \"ibgp.conf\";' /etc/bird/bird.conf; then
      echo 'include \"ibgp.conf\";' >> /etc/bird/bird.conf
    fi
    
    # Restart BIRD to apply configuration
    systemctl restart bird
  "
  
  log "iBGP configuration completed on $server"
}

# Function to install and configure looking glass
install_looking_glass() {
  local server=$1
  local ip=${PUBLIC_IPS[$server]}
  
  # Only install on LAX (primary) node - Los Angeles as the headquarters location
  if [ "$server" != "lax" ]; then
    return
  fi
  
  log "Installing looking glass on $server (Los Angeles - Primary)..."
  
  # Generate looking glass configuration for anycast IP
  local lg_ip="192.30.120.10"  # From the anycast range
  local lg_ipv6="2620:71:4000::10"  # From the anycast IPv6 range
  local lg_domain="lg.infinitum-nihil.com"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Install dependencies
    apt update
    apt install -y python3 python3-pip python3-venv redis-server nginx certbot python3-certbot-nginx socat
    
    # Add anycast IP to loopback interface
    ip addr add $lg_ip/32 dev lo
    ip -6 addr add $lg_ipv6/128 dev lo
    
    # Make the anycast IP persistent
    if ! grep -q '$lg_ip' /etc/network/interfaces; then
      echo 'post-up ip addr add $lg_ip/32 dev lo' >> /etc/network/interfaces
      echo 'post-up ip -6 addr add $lg_ipv6/128 dev lo' >> /etc/network/interfaces
    fi
    
    # Create hyperglass directory
    mkdir -p /opt/hyperglass
    cd /opt/hyperglass
    
    # Create virtual environment
    python3 -m venv venv
    source venv/bin/activate
    
    # Install hyperglass
    pip install hyperglass==1.0.0
    
    # Initialize hyperglass
    hyperglass setup
  "
  
  # Create hyperglass configuration file
  local hyperglass_config=$(cat <<EOF
# hyperglass.yaml
hyperglass:
  listen_addr: localhost
  listen_port: 8001
  debug: false
  developer_mode: false
  logging:
    logfile: /var/log/hyperglass/hyperglass.log
    level: info

ui:
  title: "BGP Anycast Looking Glass"
  favicon: /opt/hyperglass/static/favicon.ico
  logo:
    light: /opt/hyperglass/static/logo-light.png
    dark: /opt/hyperglass/static/logo-dark.png
  primary_asn: ${OUR_AS}
  org_name: "Infinitum Nihil BGP Anycast"

queries:
  - name: bgp_route
    display_name: "BGP Route"
    enable: true

  - name: bgp_community
    display_name: "BGP Community"
    enable: true

  - name: bgp_aspath
    display_name: "BGP AS Path"
    enable: true

  - name: ping
    display_name: "Ping"
    enable: true

  - name: traceroute
    display_name: "Traceroute"
    enable: true

networks:
  - name: LAX (Primary IPv6)
    network_name: Primary IPv6 (Los Angeles)
    display_name: LAX - Primary IPv6
    primary: true
    asn: ${OUR_AS}
    type: bird2
    vrfs:
      - name: default
        display_name: Global
        ipv4:
          source_address: ${OUR_IPV4_BGP_RANGE}
        ipv6:
          source_address: ${OUR_IPV6_BGP_RANGE}
    commands:
      bgp_route:
        ipv4: "show route for {target} protocol ibgp_* all"
        ipv6: "show route for {target} protocol ibgp_* all"
      bgp_community:
        ipv4: "show route where {target} protocol ibgp_* all"
        ipv6: "show route where {target} protocol ibgp_* all"
      bgp_aspath:
        ipv4: "show route where bgp_path ~ {target} protocol ibgp_* all"
        ipv6: "show route where bgp_path ~ {target} protocol ibgp_* all"
      ping:
        ipv4: "ping -c 4 -I ${RESERVED_IPS["lax"]} {target}"
        ipv6: "ping -c 4 -I ${IPV6_IPS["lax"]} {target}"
      traceroute:
        ipv4: "traceroute -4 -I -q 1 {target}"
        ipv6: "traceroute -6 -I -q 1 {target}"
    credentials:
      username: ""
      password: ""
    connection:
      device: 10.10.10.4
      port: 179
    proxy:
      command: "birdc"
      enable: true

  - name: EWR (Primary IPv4)
    network_name: Primary IPv4 (Newark)
    display_name: EWR - Primary IPv4
    asn: ${OUR_AS}
    type: bird2
    vrfs:
      - name: default
        display_name: Global
        ipv4:
          source_address: ${OUR_IPV4_BGP_RANGE}
        ipv6:
          source_address: ${OUR_IPV6_BGP_RANGE}
    commands:
      bgp_route:
        ipv4: "show route for {target} protocol ibgp_* all"
        ipv6: "show route for {target} protocol ibgp_* all"
      bgp_community:
        ipv4: "show route where {target} protocol ibgp_* all"
        ipv6: "show route where {target} protocol ibgp_* all"
      bgp_aspath:
        ipv4: "show route where bgp_path ~ {target} protocol ibgp_* all"
        ipv6: "show route where bgp_path ~ {target} protocol ibgp_* all"
      ping:
        ipv4: "ping -c 4 -I ${RESERVED_IPS["ewr"]} {target}"
        ipv6: "ping -c 4 -I ${IPV6_IPS["ewr"]} {target}"
      traceroute:
        ipv4: "traceroute -4 -I -q 1 {target}"
        ipv6: "traceroute -6 -I -q 1 {target}"
    credentials:
      username: ""
      password: ""
    connection:
      device: 10.10.10.1
      port: 179
    proxy:
      command: "birdc"
      enable: true

  - name: MIA (Secondary IPv4)
    network_name: Secondary IPv4 (Miami)
    display_name: MIA - Secondary
    asn: ${OUR_AS}
    type: bird2
    vrfs:
      - name: default
        display_name: Global
        ipv4:
          source_address: ${OUR_IPV4_BGP_RANGE}
        ipv6:
          source_address: ${OUR_IPV6_BGP_RANGE}
    commands:
      bgp_route:
        ipv4: "show route for {target} protocol ibgp_* all"
        ipv6: "show route for {target} protocol ibgp_* all"
      bgp_community:
        ipv4: "show route where {target} protocol ibgp_* all"
        ipv6: "show route where {target} protocol ibgp_* all"
      bgp_aspath:
        ipv4: "show route where bgp_path ~ {target} protocol ibgp_* all"
        ipv6: "show route where bgp_path ~ {target} protocol ibgp_* all"
      ping:
        ipv4: "ping -c 4 -I ${RESERVED_IPS["mia"]} {target}"
        ipv6: "ping -c 4 -I ${IPV6_IPS["mia"]} {target}"
      traceroute:
        ipv4: "traceroute -4 -I -q 1 {target}"
        ipv6: "traceroute -6 -I -q 1 {target}"
    credentials:
      username: ""
      password: ""
    connection:
      device: 10.10.10.2
      port: 179
    proxy:
      command: "birdc"
      enable: true

  - name: ORD (Tertiary IPv4)
    network_name: Tertiary IPv4 (Chicago)
    display_name: ORD - Tertiary
    asn: ${OUR_AS}
    type: bird2
    vrfs:
      - name: default
        display_name: Global
        ipv4:
          source_address: ${OUR_IPV4_BGP_RANGE}
        ipv6:
          source_address: ${OUR_IPV6_BGP_RANGE}
    commands:
      bgp_route:
        ipv4: "show route for {target} protocol ibgp_* all"
        ipv6: "show route for {target} protocol ibgp_* all"
      bgp_community:
        ipv4: "show route where {target} protocol ibgp_* all"
        ipv6: "show route where {target} protocol ibgp_* all"
      bgp_aspath:
        ipv4: "show route where bgp_path ~ {target} protocol ibgp_* all"
        ipv6: "show route where bgp_path ~ {target} protocol ibgp_* all"
      ping:
        ipv4: "ping -c 4 -I ${RESERVED_IPS["ord"]} {target}"
        ipv6: "ping -c 4 -I ${IPV6_IPS["ord"]} {target}"
      traceroute:
        ipv4: "traceroute -4 -I -q 1 {target}"
        ipv6: "traceroute -6 -I -q 1 {target}"
    credentials:
      username: ""
      password: ""
    connection:
      device: 10.10.10.3
      port: 179
    proxy:
      command: "birdc"
      enable: true
EOF
)

  # Deploy hyperglass configuration
  echo "$hyperglass_config" > hyperglass.yaml
  scp -i "$SSH_KEY_PATH" hyperglass.yaml "root@$ip:/opt/hyperglass/hyperglass.yaml"
  rm hyperglass.yaml
  
  # Create BIRD proxy script
  local bird_proxy=$(cat <<'EOF'
#!/bin/bash
BIRD_SOCKET="/var/run/bird/bird.ctl"

# Find BIRD socket if not at the default location
if [ ! -S "$BIRD_SOCKET" ]; then
  FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
  if [ -n "$FOUND_SOCKET" ]; then
    BIRD_SOCKET="$FOUND_SOCKET"
  fi
}

# Get command from stdin
read -r command

# Pass to BIRD socket using socat
echo "$command" | socat - UNIX-CONNECT:$BIRD_SOCKET
EOF
)

  # Deploy BIRD proxy script
  echo "$bird_proxy" > bird_proxy.sh
  scp -i "$SSH_KEY_PATH" bird_proxy.sh "root@$ip:/opt/hyperglass/bin/bird_proxy.sh"
  rm bird_proxy.sh
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Make the proxy script executable
    chmod +x /opt/hyperglass/bin/bird_proxy.sh
    
    # Build hyperglass UI
    cd /opt/hyperglass
    source venv/bin/activate
    hyperglass build-ui
    
    # Set up systemd service
    cat > /etc/systemd/system/hyperglass.service << 'EOL'
[Unit]
Description=Hyperglass Looking Glass
After=network.target redis-server.service

[Service]
User=root
WorkingDirectory=/opt/hyperglass
ExecStart=/opt/hyperglass/venv/bin/hyperglass start
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL
    
    # Enable and start services
    systemctl daemon-reload
    systemctl enable --now redis-server
    systemctl enable --now hyperglass
    
    # Set up Nginx reverse proxy
    cat > /etc/nginx/sites-available/hyperglass << 'EOL'
server {
    listen 80;
    listen [::]:80;
    server_name $lg_domain;

    location / {
        proxy_pass http://localhost:8001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL
    
    # Enable site and get SSL certificate
    ln -s /etc/nginx/sites-available/hyperglass /etc/nginx/sites-enabled/
    
    # Try to get SSL certificate if domain is pointed to this IP
    certbot --nginx -d $lg_domain --non-interactive --agree-tos -m ${LETSENCRYPT_EMAIL} || true
    
    # Restart Nginx
    systemctl restart nginx
  "
  
  # Configure BGP to announce the looking glass IPs on all servers
  for server in "${!PUBLIC_IPS[@]}"; do
    local server_ip=${PUBLIC_IPS[$server]}
    
    ssh -i "$SSH_KEY_PATH" "root@$server_ip" "
      # Create static route for the looking glass IP
      cat > /etc/bird/lg.conf << 'EOL'
# Looking Glass IP announcement
protocol static static_lg {
  ipv4 {
    table master;
  };
  route $lg_ip/32 blackhole;
}

protocol static static_lg_v6 {
  ipv6 {
    table master;
  };
  route $lg_ipv6/128 blackhole;
}
EOL
      
      # Add include statement if not already present
      if ! grep -q 'include \"lg.conf\";' /etc/bird/bird.conf; then
        echo 'include \"lg.conf\";' >> /etc/bird/bird.conf
      fi
      
      # Apply configuration
      birdc configure
    "
  done
  
  log "Looking glass installation completed on $server"
}

# Function to create route fidelity monitoring
create_route_monitoring() {
  local server=$1
  local ip=${PUBLIC_IPS[$server]}
  
  # Only install on LAX (primary) node
  if [ "$server" != "lax" ]; then
    return
  fi
  
  log "Setting up route fidelity monitoring on $server..."
  
  # Generate monitoring script
  local monitor_script=$(cat <<'EOF'
#!/bin/bash

# Define BGP speaker details
declare -A servers=(
  ["ewr"]="10.10.10.1"
  ["mia"]="10.10.10.2"
  ["ord"]="10.10.10.3"
  ["lax"]="10.10.10.4"
)

# Output file for API access
OUTPUT_FILE="/opt/hyperglass/static/route_fidelity.json"

# Check iBGP session status across all nodes
ibgp_status="{\"servers\":{"
for region in "${!servers[@]}"; do
  # Use socat to communicate with BIRD socket
  status=$(echo "show protocols" | birdc | grep "ibgp_$region" | grep -c "Established" || echo "0")
  ibgp_status+="\"$region\":$status,"
done
ibgp_status=${ibgp_status%,}
ibgp_status+="},"

# Check IPv4 and IPv6 route propagation
ipv4_routes="{\"servers\":{"
ipv6_routes="{\"servers\":{"

for region in "${!servers[@]}"; do
  # Check IPv4 route propagation
  ipv4_count=$(echo "show route for 192.30.120.0/23 all" | birdc | grep -c "unicast" || echo "0")
  ipv4_routes+="\"$region\":$ipv4_count,"
  
  # Check IPv6 route propagation
  ipv6_count=$(echo "show route for 2620:71:4000::/48 all" | birdc | grep -c "unicast" || echo "0")
  ipv6_routes+="\"$region\":$ipv6_count,"
done

ipv4_routes=${ipv4_routes%,}
ipv4_routes+="}},"

ipv6_routes=${ipv6_routes%,}
ipv6_routes+="}},"

# Check mesh network status
mesh_status="{\"servers\":{"
for region in "${!servers[@]}"; do
  # Check WireGuard connection status
  status=$(wg show wg0 | grep -c "latest handshake" || echo "0")
  mesh_status+="\"$region\":$status,"
done
mesh_status=${mesh_status%,}
mesh_status+="}}"

# Create final JSON
json_output="{"
json_output+="\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
json_output+="\"ibgp_status\":$ibgp_status"
json_output+="\"ipv4_routes\":$ipv4_routes"
json_output+="\"ipv6_routes\":$ipv6_routes"
json_output+="\"mesh_status\":$mesh_status"
json_output+="}"

# Write to file for API access
echo $json_output > $OUTPUT_FILE
chmod 644 $OUTPUT_FILE
EOF
)

  # Deploy monitoring script
  echo "$monitor_script" > monitor_route_fidelity.sh
  scp -i "$SSH_KEY_PATH" monitor_route_fidelity.sh "root@$ip:/opt/hyperglass/bin/monitor_route_fidelity.sh"
  rm monitor_route_fidelity.sh
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Make the script executable
    chmod +x /opt/hyperglass/bin/monitor_route_fidelity.sh
    
    # Add to crontab
    (crontab -l 2>/dev/null; echo '*/5 * * * * /opt/hyperglass/bin/monitor_route_fidelity.sh') | crontab -
    
    # Run it once
    /opt/hyperglass/bin/monitor_route_fidelity.sh
  "
  
  log "Route fidelity monitoring setup completed on $server"
}

# Function to verify mesh network
verify_mesh_network() {
  log "Verifying mesh network and iBGP setup..."
  
  for server in "${!PUBLIC_IPS[@]}"; do
    local ip=${PUBLIC_IPS[$server]}
    
    log "Checking WireGuard status on $server..."
    ssh -i "$SSH_KEY_PATH" "root@$ip" "wg show"
    
    log "Checking iBGP status on $server..."
    ssh -i "$SSH_KEY_PATH" "root@$ip" "birdc show protocols | grep ibgp"
    
    log "Checking route propagation on $server..."
    ssh -i "$SSH_KEY_PATH" "root@$ip" "birdc show route where source ~ \".*ibgp.*\""
  done
  
  log "Mesh network verification completed"
}

# Main script execution

# Define server IDs for WireGuard IPs
declare -A SERVER_IDS=(
  ["ewr"]="1"
  ["mia"]="2"
  ["ord"]="3"
  ["lax"]="4"
)

# Array to store public keys
declare -A PUBLIC_KEYS

log "Starting BGP mesh network and looking glass setup..."

# Step 1: Install WireGuard on all servers
for server in "${!PUBLIC_IPS[@]}"; do
  install_wireguard "$server"
done

# Step 2: Generate WireGuard keys on all servers
for server in "${!PUBLIC_IPS[@]}"; do
  generate_wireguard_keys "$server"
done

# Step 3: Create WireGuard configurations
for server in "${!PUBLIC_IPS[@]}"; do
  create_wireguard_config "$server" "${SERVER_IDS[$server]}"
done

# Step 4: Configure iBGP
for server in "${!PUBLIC_IPS[@]}"; do
  configure_ibgp "$server"
done

# Step 5: Install looking glass on primary node
install_looking_glass "lax"

# Step 6: Create route fidelity monitoring
create_route_monitoring "lax"

# Step 7: Verify mesh network
verify_mesh_network

log "BGP mesh network and looking glass setup completed successfully"
log "Looking glass should be available at http://$lg_domain once DNS is configured"
log "For immediate access, you can use http://${RESERVED_IPS["lax"]}"

# Final instructions
echo "=============================================================================="
echo "BGP Mesh Network and Looking Glass Implementation Complete!"
echo "=============================================================================="
echo ""
echo "To use the looking glass, configure the following DNS record:"
echo "  $lg_domain -> ${RESERVED_IPS["lax"]} (IPv4)"
echo "  $lg_domain -> ${IPV6_IPS["lax"]} (IPv6)"
echo ""
echo "The mesh network uses the following IPs:"
echo "  EWR: 10.10.10.1 (Public IP: ${PUBLIC_IPS["ewr"]})"
echo "  MIA: 10.10.10.2 (Public IP: ${PUBLIC_IPS["mia"]})"
echo "  ORD: 10.10.10.3 (Public IP: ${PUBLIC_IPS["ord"]})"
echo "  LAX: 10.10.10.4 (Public IP: ${PUBLIC_IPS["lax"]})"
echo ""
echo "For detailed logs, see: $LOG_FILE"
echo "=============================================================================="