#!/bin/bash
# implement_ibgp.sh - Configure iBGP over WireGuard mesh network
# Sets up iBGP with LAX as route reflector for optimized BGP route exchange

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed
CONFIG_FILE="/home/normtodd/birdbgp/config_files/config.json"
BIRD_CONFIG_DIR="/etc/bird"
WG_BASE_IP="10.10.10"  # WireGuard subnet base
OUR_AS="64512"         # Default AS number (will be overridden if found in config)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file setup
LOG_FILE="ibgp_implementation_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to extract server data from config.json
extract_server_data() {
  echo -e "${BLUE}Extracting server data from config.json...${NC}"
  
  # Check if jq is installed
  if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Please install jq with: sudo apt-get install -y jq"
    exit 1
  fi
  
  # Check if config file exists
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
  fi
  
  # Extract server data
  local providers=$(jq -r '.cloud_providers | keys[]' "$CONFIG_FILE")
  
  declare -A SERVER_IPS
  declare -A SERVER_ROLES
  declare -A SERVER_WG_IPS
  
  for provider in $providers; do
    echo -e "${BLUE}Processing provider: $provider${NC}"
    
    # Get all regions
    local regions=$(jq -r ".cloud_providers.$provider.servers | keys[]" "$CONFIG_FILE")
    
    for region in $regions; do
      echo -e "${BLUE}Processing region: $region${NC}"
      
      # Get all locations in this region
      local locations=$(jq -r ".cloud_providers.$provider.servers.\"$region\" | keys[]" "$CONFIG_FILE")
      
      for location in $locations; do
        echo -e "${BLUE}Processing location: $location${NC}"
        
        # Extract IPv4 address
        local ipv4=$(jq -r ".cloud_providers.$provider.servers.\"$region\".\"$location\".ipv4.address" "$CONFIG_FILE")
        
        # Extract role
        local role=$(jq -r ".cloud_providers.$provider.servers.\"$region\".\"$location\".ipv4.role" "$CONFIG_FILE")
        
        if [ "$ipv4" != "null" ] && [ "$ipv4" != "" ]; then
          echo -e "${GREEN}Added server $location: $ipv4 (Role: $role)${NC}"
          SERVER_IPS["$location"]="$ipv4"
          SERVER_ROLES["$location"]="$role"
          
          # Assign WireGuard IPs based on config extraction
          local index=1
          case "$location" in
            "lax") index=1 ;;
            "ewr") index=2 ;;
            "mia") index=3 ;;
            "ord") index=4 ;;
            *) index=$((index+1)) ;;
          esac
          
          SERVER_WG_IPS["$location"]="$WG_BASE_IP.$index"
        fi
      done
    done
  done
  
  # Extract AS number if available
  if jq -e '.global_metadata.bgp_as_number' "$CONFIG_FILE" > /dev/null 2>&1; then
    OUR_AS=$(jq -r '.global_metadata.bgp_as_number' "$CONFIG_FILE")
    echo -e "${GREEN}Found AS number in config: $OUR_AS${NC}"
  else
    echo -e "${YELLOW}AS number not found in config, using default: $OUR_AS${NC}"
  fi
  
  # Extract network blocks if available
  if jq -e '.global_metadata.network_blocks' "$CONFIG_FILE" > /dev/null 2>&1; then
    IPV4_BLOCKS=$(jq -r '.global_metadata.network_blocks.ipv4[]' "$CONFIG_FILE" | tr '\n' ' ')
    IPV6_BLOCKS=$(jq -r '.global_metadata.network_blocks.ipv6[]' "$CONFIG_FILE" | tr '\n' ' ')
    echo -e "${GREEN}Found network blocks in config: IPv4: $IPV4_BLOCKS, IPv6: $IPV6_BLOCKS${NC}"
  else
    IPV4_BLOCKS="192.30.120.0/23"
    IPV6_BLOCKS="2620:71:4000::/48"
    echo -e "${YELLOW}Network blocks not found in config, using defaults: IPv4: $IPV4_BLOCKS, IPv6: $IPV6_BLOCKS${NC}"
  fi
  
  # Export the network blocks
  export IPV4_BLOCKS
  export IPV6_BLOCKS
  
  # Create globally accessible arrays (declare -g makes them global)
  declare -gA SERVER_IPS_GLOBAL
  declare -gA SERVER_ROLES_GLOBAL
  declare -gA SERVER_WG_IPS_GLOBAL

  # Copy values to global arrays
  for server in "${!SERVER_IPS[@]}"; do
    SERVER_IPS_GLOBAL[$server]=${SERVER_IPS[$server]}
    SERVER_ROLES_GLOBAL[$server]=${SERVER_ROLES[$server]}
    SERVER_WG_IPS_GLOBAL[$server]=${SERVER_WG_IPS[$server]}
  done
  
  # Output the extracted data
  echo -e "${YELLOW}Extracted Server Information:${NC}"
  for server in "${!SERVER_IPS_GLOBAL[@]}"; do
    echo -e "${GREEN}$server: ${SERVER_IPS_GLOBAL[$server]} (Role: ${SERVER_ROLES_GLOBAL[$server]}, WG IP: ${SERVER_WG_IPS_GLOBAL[$server]})${NC}"
  done
  
  # Set global variables
  OUR_AS_GLOBAL=$OUR_AS
  IPV4_BLOCKS_GLOBAL=$IPV4_BLOCKS
  IPV6_BLOCKS_GLOBAL=$IPV6_BLOCKS
}

# Function to check if BIRD is installed and running
check_bird() {
  local server=$1
  local ip=${SERVER_IPS_GLOBAL[$server]}
  
  echo -e "${BLUE}Checking BIRD status on $server ($ip)...${NC}"
  
  local bird_installed=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "
    if command -v birdc &> /dev/null; then
      echo 'installed'
    else
      echo 'not_installed'
    fi
  ")
  
  if [ "$bird_installed" = "not_installed" ]; then
    echo -e "${RED}BIRD is not installed on $server. Installing BIRD...${NC}"
    ssh -i "$SSH_KEY_PATH" "root@$ip" "
      # Fix any interrupted package operations
      dpkg --configure -a
      
      # Update package lists
      DEBIAN_FRONTEND=noninteractive apt-get update
      
      # Install BIRD
      DEBIAN_FRONTEND=noninteractive apt-get install -y bird2
      
      # Ensure BIRD is enabled
      systemctl enable bird
    " || {
      echo -e "${RED}Failed to install BIRD on $server.${NC}"
      return 1
    }
  fi
  
  # Check if BIRD service is running
  local bird_running=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "
    if systemctl is-active bird &> /dev/null; then
      echo 'running'
    else
      echo 'not_running'
    fi
  ")
  
  if [ "$bird_running" = "not_running" ]; then
    echo -e "${YELLOW}BIRD service is not running on $server. Starting BIRD...${NC}"
    ssh -i "$SSH_KEY_PATH" "root@$ip" "
      systemctl start bird
    " || {
      echo -e "${RED}Failed to start BIRD on $server.${NC}"
      return 1
    }
  fi
  
  echo -e "${GREEN}BIRD is installed and running on $server.${NC}"
  return 0
}

# Function to generate iBGP configuration for route reflector
generate_rr_config() {
  local server=$1
  
  echo -e "${BLUE}Generating iBGP route reflector configuration for $server...${NC}"
  
  local ibgp_conf="# iBGP Route Reflector Configuration
# Generated by implement_ibgp.sh on $(date)
# Route Reflector: $server (${SERVER_WG_IPS_GLOBAL[$server]})

# Define route reflector cluster ID
define rr_cluster_id = 1;

# Template for iBGP clients
template bgp ibgp_clients {
  local as $OUR_AS;
  rr client;
  rr cluster id rr_cluster_id;
  next hop self;
  direct;
  igp table master;
  
  # Import and export filters
  import all;
  export all;
}

# iBGP client sessions
"
  
  # Add client configurations
  for client in "${!SERVER_IPS_GLOBAL[@]}"; do
    if [ "$client" != "$server" ]; then
      ibgp_conf+="protocol bgp ibgp_$client from ibgp_clients {
  neighbor ${SERVER_WG_IPS_GLOBAL[$client]} as $OUR_AS_GLOBAL;
  description \"iBGP to $client (${SERVER_ROLES_GLOBAL[$client]})\";
}

"
    fi
  done
  
  echo "$ibgp_conf"
}

# Function to generate iBGP configuration for clients
generate_client_config() {
  local server=$1
  local rr_server=$2
  
  echo -e "${BLUE}Generating iBGP client configuration for $server...${NC}"
  
  local ibgp_conf="# iBGP Client Configuration
# Generated by implement_ibgp.sh on $(date)
# Client: $server (${SERVER_WG_IPS_GLOBAL[$server]})
# Route Reflector: $rr_server (${SERVER_WG_IPS_GLOBAL[$rr_server]})

# iBGP session to route reflector
protocol bgp ibgp_$rr_server {
  local as $OUR_AS_GLOBAL;
  neighbor ${SERVER_WG_IPS_GLOBAL[$rr_server]} as $OUR_AS_GLOBAL;
  next hop self;
  direct;
  igp table master;
  
  # Import and export filters
  import all;
  export all;
  
  description \"iBGP to Route Reflector ($rr_server)\";
}
"
  
  echo "$ibgp_conf"
}

# Function to deploy iBGP configuration to a server
deploy_ibgp_config() {
  local server=$1
  local ip=${SERVER_IPS_GLOBAL[$server]}
  local config=$2
  
  echo -e "${BLUE}Deploying iBGP configuration to $server ($ip)...${NC}"
  
  # Create config directory if it doesn't exist
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    mkdir -p $BIRD_CONFIG_DIR
  " || {
    echo -e "${RED}Failed to create config directory on $server.${NC}"
    return 1
  }
  
  # Write configuration to a temporary file
  local temp_file=$(mktemp)
  echo "$config" > "$temp_file"
  
  # Upload configuration to server
  scp -i "$SSH_KEY_PATH" "$temp_file" "root@$ip:$BIRD_CONFIG_DIR/ibgp.conf" || {
    echo -e "${RED}Failed to upload iBGP configuration to $server.${NC}"
    rm "$temp_file"
    return 1
  }
  
  # Clean up
  rm "$temp_file"
  
  # Update main BIRD configuration to include iBGP configuration
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Check if main configuration exists
    if [ ! -f $BIRD_CONFIG_DIR/bird.conf ]; then
      # Create basic bird.conf if it doesn't exist
      cat > $BIRD_CONFIG_DIR/bird.conf << 'EOL'
# Basic BIRD configuration
log syslog all;
router id ${SERVER_WG_IPS_GLOBAL[$server]};

# Include other configuration files
include \"ibgp.conf\";
EOL
    else
      # Add include statement if not already present
      if ! grep -q 'include \"ibgp.conf\";' $BIRD_CONFIG_DIR/bird.conf; then
        echo 'include \"ibgp.conf\";' >> $BIRD_CONFIG_DIR/bird.conf
      fi
    fi
    
    # Apply configuration
    birdc configure || {
      echo 'Failed to apply BIRD configuration'
      exit 1
    }
    
    echo 'BIRD configuration applied successfully'
  " || {
    echo -e "${RED}Failed to update BIRD configuration on $server.${NC}"
    return 1
  }
  
  echo -e "${GREEN}iBGP configuration deployed successfully to $server.${NC}"
  return 0
}

# Function to verify iBGP sessions
verify_ibgp() {
  local server=$1
  local ip=${SERVER_IPS_GLOBAL[$server]}
  
  echo -e "${BLUE}Verifying iBGP sessions on $server ($ip)...${NC}"
  
  # Check iBGP protocol status
  local ibgp_status=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "
    birdc show protocols | grep -A 1 'ibgp_' || echo 'No iBGP sessions found'
  ")
  
  echo -e "${YELLOW}iBGP status on $server:${NC}"
  echo "$ibgp_status"
  
  # Check for established sessions
  local established_count=$(echo "$ibgp_status" | grep -c "Established" || echo "0")
  
  if [ "$established_count" -gt 0 ]; then
    echo -e "${GREEN}$established_count iBGP sessions established on $server.${NC}"
  else
    echo -e "${RED}No established iBGP sessions found on $server.${NC}"
    
    # Debug information
    echo -e "${YELLOW}Debug information:${NC}"
    ssh -i "$SSH_KEY_PATH" "root@$ip" "
      echo 'BIRD status:'
      systemctl status bird
      
      echo 'WireGuard status:'
      wg show
      
      echo 'Network connectivity to peers:'
      $(for peer in "${!SERVER_WG_IPS[@]}"; do
          if [ \"$peer\" != \"$server\" ]; then
            echo \"ping -c 1 ${SERVER_WG_IPS[$peer]} || echo 'Cannot ping ${SERVER_WG_IPS[$peer]}'\"
          fi
        done)
      
      echo 'BIRD log:'
      tail -n 20 /var/log/bird.log 2>/dev/null || tail -n 20 /var/log/syslog | grep bird
    "
  fi
}

# Function to setup looking glass on the primary node
setup_looking_glass() {
  local server=$1  # This should be the primary node (LAX)
  local ip=${SERVER_IPS_GLOBAL[$server]}
  
  echo -e "${BLUE}Setting up looking glass on $server ($ip)...${NC}"
  
  # Install required packages
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Fix any interrupted package operations
    dpkg --configure -a
    
    # Update package lists
    DEBIAN_FRONTEND=noninteractive apt-get update
    
    # Install required packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python3-venv git nginx socat
    
    # Create directory for looking glass
    mkdir -p /opt/looking-glass
    cd /opt/looking-glass
    
    # Clone looking glass repository
    if [ ! -d /opt/looking-glass/bird-lg ]; then
      git clone https://github.com/xvzf/bird-lg.git
      cd bird-lg
    else
      cd bird-lg
      git pull
    fi
    
    # Create virtual environment
    python3 -m venv venv
    source venv/bin/activate
    
    # Install dependencies
    pip install -r requirements.txt
    
    # Create configuration
    cat > /opt/looking-glass/bird-lg/config.py << EOL
# Configuration for bird-lg
DOMAIN = '${SERVER_IPS[$server]}'
DOMAIN_DISPLAY = 'BGP Looking Glass'
PROTOCOLS = ['BGP']
RESULTS_PER_PAGE = 50
PROXY_TIMEOUT = 60
EOL
    
    # Create proxy configuration for each node
    cat > /opt/looking-glass/bird-lg/proxy.conf << EOL
# Bird Looking Glass Proxy Configuration
# Primary node: $server (${SERVER_IPS[$server]})
EOL
    
    # Add entries for each node
    $(for node in "${!SERVER_IPS_GLOBAL[@]}"; do
        echo "echo \"${SERVER_WG_IPS_GLOBAL[$node]} $node\" >> /opt/looking-glass/bird-lg/proxy.conf"
      done)
    
    # Create systemd service for bird-lg
    cat > /etc/systemd/system/bird-lg.service << 'EOL'
[Unit]
Description=Bird Looking Glass
After=network.target

[Service]
User=root
WorkingDirectory=/opt/looking-glass/bird-lg
ExecStart=/opt/looking-glass/bird-lg/venv/bin/python3 lg.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL
    
    # Create systemd service for bird-lg-proxy on each server
    cat > /etc/systemd/system/bird-lg-proxy.service << 'EOL'
[Unit]
Description=Bird Looking Glass Proxy
After=network.target

[Service]
User=root
WorkingDirectory=/opt/looking-glass/bird-lg
ExecStart=/opt/looking-glass/bird-lg/venv/bin/python3 proxy.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL
    
    # Enable and start services
    systemctl daemon-reload
    systemctl enable bird-lg.service
    systemctl enable bird-lg-proxy.service
    systemctl start bird-lg.service
    systemctl start bird-lg-proxy.service
    
    # Configure Nginx to proxy requests to bird-lg
    cat > /etc/nginx/sites-available/bird-lg << 'EOL'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOL
    
    # Enable site
    ln -sf /etc/nginx/sites-available/bird-lg /etc/nginx/sites-enabled/
    
    # Restart Nginx
    systemctl restart nginx
    
    echo 'Looking glass setup completed'
  " || {
    echo -e "${RED}Failed to set up looking glass on $server.${NC}"
    return 1
  }
  
  echo -e "${GREEN}Looking glass set up successfully on $server.${NC}"
  echo -e "${YELLOW}Looking glass is available at: http://${SERVER_IPS[$server]}/${NC}"
  
  return 0
}

# Function to configure bird-lg-proxy on client nodes
setup_proxy_clients() {
  # Skip the primary node as it's already configured
  local primary_node=""
  
  # Find the primary node
  for server in "${!SERVER_ROLES[@]}"; do
    if [ "${SERVER_ROLES[$server]}" = "primary" ]; then
      primary_node="$server"
      break
    fi
  done
  
  if [ -z "$primary_node" ]; then
    echo -e "${RED}No primary node found. Cannot set up proxy clients.${NC}"
    return 1
  fi
  
  for server in "${!SERVER_IPS[@]}"; do
    # Skip the primary node
    if [ "$server" = "$primary_node" ]; then
      continue
    fi
    
    local ip=${SERVER_IPS[$server]}
    
    echo -e "${BLUE}Setting up bird-lg-proxy on $server ($ip)...${NC}"
    
    ssh -i "$SSH_KEY_PATH" "root@$ip" "
      # Fix any interrupted package operations
      dpkg --configure -a
      
      # Update package lists
      DEBIAN_FRONTEND=noninteractive apt-get update
      
      # Install required packages
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python3-venv git socat
      
      # Create directory for looking glass
      mkdir -p /opt/looking-glass
      cd /opt/looking-glass
      
      # Clone looking glass repository
      if [ ! -d /opt/looking-glass/bird-lg ]; then
        git clone https://github.com/xvzf/bird-lg.git
        cd bird-lg
      else
        cd bird-lg
        git pull
      fi
      
      # Create virtual environment
      python3 -m venv venv
      source venv/bin/activate
      
      # Install dependencies
      pip install -r requirements.txt
      
      # Create systemd service for bird-lg-proxy
      cat > /etc/systemd/system/bird-lg-proxy.service << 'EOL'
[Unit]
Description=Bird Looking Glass Proxy
After=network.target

[Service]
User=root
WorkingDirectory=/opt/looking-glass/bird-lg
ExecStart=/opt/looking-glass/bird-lg/venv/bin/python3 proxy.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL
      
      # Enable and start service
      systemctl daemon-reload
      systemctl enable bird-lg-proxy.service
      systemctl start bird-lg-proxy.service
      
      echo 'Bird LG proxy setup completed'
    " || {
      echo -e "${RED}Failed to set up bird-lg-proxy on $server.${NC}"
      return 1
    }
    
    echo -e "${GREEN}Bird LG proxy set up successfully on $server.${NC}"
  done
  
  return 0
}

# Main function
main() {
  echo -e "${BLUE}Starting iBGP implementation over WireGuard mesh network...${NC}"
  
  # Extract server data
  extract_server_data
  
  # Determine route reflector (should be the primary node, usually LAX)
  RR_SERVER="lax"  # Set default to lax since we know it's the primary
  
  # Verify it exists in our server list
  if [[ -z "${SERVER_IPS_GLOBAL[$RR_SERVER]}" ]]; then
    echo -e "${RED}Error: Primary node 'lax' not found in server list.${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Using $RR_SERVER as route reflector.${NC}"
  
  # Check BIRD on all servers
  for server in "${!SERVER_IPS_GLOBAL[@]}"; do
    check_bird "$server" || exit 1
  done
  
  # Generate and deploy route reflector configuration
  rr_config=$(generate_rr_config "$RR_SERVER")
  deploy_ibgp_config "$RR_SERVER" "$rr_config" || exit 1
  
  # Generate and deploy client configurations
  for server in "${!SERVER_IPS_GLOBAL[@]}"; do
    if [ "$server" != "$RR_SERVER" ]; then
      client_config=$(generate_client_config "$server" "$RR_SERVER")
      deploy_ibgp_config "$server" "$client_config" || exit 1
    fi
  done
  
  # Deploy static routes for our network blocks
  for server in "${!SERVER_IPS_GLOBAL[@]}"; do
    local ip=${SERVER_IPS_GLOBAL[$server]}
    
    echo -e "${BLUE}Deploying static routes for network blocks on $server ($ip)...${NC}"
    
    # Create static routes configuration
    local static_routes="# Static routes for anycast network blocks
# Generated by implement_ibgp.sh on $(date)

protocol static static_anycast_v4 {
  ipv4 {
    table master;
  };
  
  # IPv4 anycast network blocks
"
    
    # Add IPv4 blocks
    for block in $IPV4_BLOCKS; do
      static_routes+="  route $block blackhole;\n"
    done
    
    static_routes+="}

protocol static static_anycast_v6 {
  ipv6 {
    table master;
  };
  
  # IPv6 anycast network blocks
"
    
    # Add IPv6 blocks
    for block in $IPV6_BLOCKS; do
      static_routes+="  route $block blackhole;\n"
    done
    
    static_routes+="}
"
    
    # Write static routes to a temporary file
    local temp_file=$(mktemp)
    echo -e "$static_routes" > "$temp_file"
    
    # Upload static routes to server
    scp -i "$SSH_KEY_PATH" "$temp_file" "root@$ip:$BIRD_CONFIG_DIR/static_routes.conf" || {
      echo -e "${RED}Failed to upload static routes configuration to $server.${NC}"
      rm "$temp_file"
      return 1
    }
    
    # Clean up
    rm "$temp_file"
    
    # Update main BIRD configuration to include static routes
    ssh -i "$SSH_KEY_PATH" "root@$ip" "
      # Add include statement if not already present
      if ! grep -q 'include \"static_routes.conf\";' $BIRD_CONFIG_DIR/bird.conf; then
        echo 'include \"static_routes.conf\";' >> $BIRD_CONFIG_DIR/bird.conf
      fi
      
      # Apply configuration
      birdc configure || {
        echo 'Failed to apply BIRD configuration'
        exit 1
      }
      
      echo 'Static routes configuration applied successfully'
    " || {
      echo -e "${RED}Failed to update BIRD configuration on $server.${NC}"
      return 1
    }
    
    echo -e "${GREEN}Static routes deployed successfully to $server.${NC}"
  done
  
  # Verify iBGP sessions
  echo -e "${BLUE}Waiting for iBGP sessions to establish...${NC}"
  sleep 10  # Give BIRD some time to establish sessions
  
  for server in "${!SERVER_IPS_GLOBAL[@]}"; do
    verify_ibgp "$server" || echo -e "${YELLOW}iBGP verification failed on $server, but continuing...${NC}"
  done
  
  # Set up looking glass on the primary node
  setup_looking_glass "$RR_SERVER" || exit 1
  
  # Set up proxy clients on other nodes
  setup_proxy_clients || exit 1
  
  echo -e "${GREEN}iBGP implementation completed successfully!${NC}"
  echo -e "${YELLOW}Looking glass is available at: http://${SERVER_IPS[$RR_SERVER]}/${NC}"
  echo -e "${YELLOW}You can now verify BGP routes and sessions through the looking glass.${NC}"
}

# Run the main function
main