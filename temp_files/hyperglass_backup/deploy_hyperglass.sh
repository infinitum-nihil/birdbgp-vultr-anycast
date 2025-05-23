#!/bin/bash
# Script to deploy hyperglass on all BGP speakers with Traefik and CrowdSec integration

# Use noninteractive mode for package installation
export DEBIAN_FRONTEND=noninteractive

# Source environment variables
source "$(dirname "$0")/.env"

# Server information
PRIMARY_IP=$(cat "$HOME/birdbgp/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
SECONDARY_IP=$(cat "$HOME/birdbgp/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
TERTIARY_IP=$(cat "$HOME/birdbgp/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
QUATERNARY_IP=$(cat "$HOME/birdbgp/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)

# Anycast IPs to assign
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"

# Domain and DNS settings
DOMAIN="infinitum-nihil.com"
DNS_PROVIDER="${DNS_PROVIDER:-dnsmadeeasy}"
DNS_API_KEY="${DNS_API_KEY:-145af300-0ad0-4268-b1be-950378546dee}"

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"

# Check for DNSMadeEasy API Secret in .env or ask for it
if [ -z "$DNS_API_SECRET" ]; then
  # Check if it's in the .env file but not loaded
  if grep -q "^DNS_API_SECRET=" "$(dirname "$0")/.env"; then
    DNS_API_SECRET=$(grep "^DNS_API_SECRET=" "$(dirname "$0")/.env" | cut -d= -f2)
  else
    # Not in .env, prompt for it
    read -p "Enter DNSMadeEasy API Secret: " DNS_API_SECRET
    if [ -z "$DNS_API_SECRET" ]; then
      echo -e "${RED}Error: DNSMadeEasy API Secret is required.${RESET}"
      exit 1
    fi
    
    # Save it to .env for future use
    echo "DNS_API_SECRET=$DNS_API_SECRET" >> "$(dirname "$0")/.env"
    echo -e "${GREEN}Added DNS_API_SECRET to .env file${RESET}"
  fi
fi

# Set up email for Let's Encrypt
if [ -z "$LETSENCRYPT_EMAIL" ]; then
  read -p "Enter email for Let's Encrypt certificates: " LETSENCRYPT_EMAIL
  if [ -z "$LETSENCRYPT_EMAIL" ]; then
    echo -e "${RED}Error: Email is required for Let's Encrypt.${RESET}"
    exit 1
  fi
  
  # Add to .env file
  echo "LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL" >> .env
  echo -e "${GREEN}Added LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL to .env file${RESET}"
fi

# Generate a secure password for Traefik dashboard
# Use OpenSSL for generating a secure random password (more portable than CrowdSec tools)
if command -v openssl >/dev/null 2>&1; then
  TRAEFIK_ADMIN_PASSWORD=$(openssl rand -base64 12 2>/dev/null || echo "SecureTraefikAdmin")
else
  TRAEFIK_ADMIN_PASSWORD="SecureTraefikAdmin"
fi

# Hash password for basic auth (using OpenSSL if available)
if command -v openssl >/dev/null 2>&1; then
  HASHED_PASSWORD=$(openssl passwd -apr1 "$TRAEFIK_ADMIN_PASSWORD" 2>/dev/null)
fi

# If hash failed, use a default but secure password
if [ -z "$HASHED_PASSWORD" ]; then
  TRAEFIK_ADMIN_PASSWORD="SecureTraefikAdmin"
  HASHED_PASSWORD='$apr1$ruca84Hq$mbjdMZBAG.KWn7vfN/SNK/' # admin:SecureTraefikAdmin
fi

echo -e "${BOLD}Hyperglass Deployment to BGP Speakers${RESET}"
echo "======================================="
echo -e "${GREEN}Primary (LAX):${RESET} $PRIMARY_IP"
echo -e "${GREEN}Secondary (EWR):${RESET} $SECONDARY_IP"
echo -e "${GREEN}Tertiary (MIA):${RESET} $TERTIARY_IP"
echo -e "${GREEN}Quaternary (ORD):${RESET} $QUATERNARY_IP"
echo "======================================="
echo "Assigning Anycast IPs: $ANYCAST_IPV4 and $ANYCAST_IPV6"
echo "Domain name: $DOMAIN"
echo "Let's Encrypt email: $LETSENCRYPT_EMAIL"
echo "DNS Provider: $DNS_PROVIDER"
echo ""

# Function to deploy hyperglass to a server
deploy_hyperglass() {
  local server_ip=$1
  local server_name=$2
  local region=$3
  
  echo -e "${BOLD}Deploying to $server_name ($region) - $server_ip...${RESET}"
  
  # Create the deployment script to run on the remote server
  cat > /tmp/hyperglass_setup.sh << EOF
#!/bin/bash
set -e

# Configuration variables
ANYCAST_IPV4="$ANYCAST_IPV4"
ANYCAST_IPV6="$ANYCAST_IPV6"
DOMAIN="$DOMAIN"
LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL"
OUR_AS="$OUR_AS"
DNS_PROVIDER="$DNS_PROVIDER"
DNS_API_KEY="$DNS_API_KEY"
DNS_API_SECRET="$DNS_API_SECRET"
TRAEFIK_ADMIN_PASSWORD="$TRAEFIK_ADMIN_PASSWORD"
HASHED_PASSWORD='$HASHED_PASSWORD'
DEST_DIR="/opt/hyperglass"
TRAEFIK_DIR="/opt/traefik"

# Set noninteractive mode to avoid prompts
export DEBIAN_FRONTEND=noninteractive

echo "[1] Updating system packages..."
apt update && DEBIAN_FRONTEND=noninteractive apt upgrade -y

echo "[2] Installing prerequisites..."
# Pre-configure iptables-persistent to automatically accept saving rules
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

# Check for any pending unattended upgrades and wait for them to complete
if pgrep unattended-upgrade > /dev/null; then
  echo "Waiting for unattended-upgrade to complete..."
  while pgrep unattended-upgrade > /dev/null; do
    sleep 5
  done
  echo "Unattended-upgrade completed"
fi

# Clear any apt locks that might be present
if [ -f /var/lib/apt/lists/lock ]; then
  echo "Clearing apt locks..."
  lsof /var/lib/apt/lists/lock || true
  lsof /var/lib/dpkg/lock-frontend || true
  lsof /var/lib/dpkg/lock || true
  # Only force-remove locks if they're stale (no process is using them)
  if ! lsof /var/lib/apt/lists/lock >/dev/null 2>&1; then
    rm -f /var/lib/apt/lists/lock
  fi
  if ! lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/lock-frontend
  fi
  if ! lsof /var/lib/dpkg/lock >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/lock
  fi
fi

# Install required packages
DEBIAN_FRONTEND=noninteractive apt install -y apt-transport-https ca-certificates curl software-properties-common git socat python3 python3-pip iptables-persistent netfilter-persistent jq apache2-utils

echo "[3] Setting up Docker..."
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  systemctl enable docker
  systemctl start docker
fi

echo "[4] Installing Docker Compose..."
if ! command -v docker compose &> /dev/null; then
  mkdir -p ~/.docker/cli-plugins/
  curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
  chmod +x ~/.docker/cli-plugins/docker-compose
  ln -sf ~/.docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
fi

echo "[5] Setting up anycast IP addresses..."
# Get main interface name
MAIN_INTERFACE=\$(ip -br l | grep -v -E '(lo|veth|docker|dummy)' | awk '{print \$1}')

# Create dummy interface if not exists
if ! ip link show dummy0 &>/dev/null; then
  echo "Creating dummy0 interface"
  modprobe dummy
  ip link add dummy0 type dummy
  ip link set dummy0 up
  echo "dummy" > /etc/modules-load.d/dummy.conf
fi

# Add anycast IPs to dummy interface
ip addr add \$ANYCAST_IPV4/32 dev dummy0 2>/dev/null || echo "IPv4 anycast IP already exists"
ip -6 addr add \$ANYCAST_IPV6/128 dev dummy0 2>/dev/null || echo "IPv6 anycast IP already exists"

# Create netplan directory if it doesn't exist
mkdir -p /etc/netplan

# Create temporary netplan file first
cat > /tmp/60-anycast.yaml << NETPLAN
network:
  version: 2
  ethernets:
    dummy0:
      match:
        name: dummy0
      addresses:
        - \$ANYCAST_IPV4/32
        - \$ANYCAST_IPV6/128
NETPLAN

# Copy with correct permissions to the final location
install -m 0640 /tmp/60-anycast.yaml /etc/netplan/60-anycast.yaml

netplan apply

# Setup UFW if installed
if command -v ufw &>/dev/null; then
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw reload
fi

# Setup iptables rules
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Save iptables rules
netfilter-persistent save

# Create a flag file to indicate we've completed the first phase
touch /tmp/hyperglass_phase1_complete

# Create systemd service to continue setup after reboot
cat > /etc/systemd/system/hyperglass-setup-phase2.service << SYSTEMD
[Unit]
Description=Hyperglass Setup Phase 2
After=network.target docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash /tmp/hyperglass_setup_phase2.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
SYSTEMD

# Create phase 2 script
cat > /tmp/hyperglass_setup_phase2.sh << 'PHASE2'
#!/bin/bash
set -e

# Load configuration variables from environment file
source /tmp/hyperglass_env.sh

# Log all output for debugging
exec > >(tee -a /tmp/hyperglass_phase2.log) 2>&1

echo "Starting Hyperglass Phase 2 Setup at $(date)"
echo "Working with domain: $DOMAIN"

# Disable the service so it doesn't run again on next reboot
systemctl disable hyperglass-setup-phase2.service

echo "[6] Creating Traefik configuration..."
# Create Traefik directory
mkdir -p $TRAEFIK_DIR/data $TRAEFIK_DIR/config $TRAEFIK_DIR/logs

# Create acme.json with correct permissions
touch $TRAEFIK_DIR/data/acme.json
chmod 600 $TRAEFIK_DIR/data/acme.json

# Create Traefik dynamic configuration for CrowdSec
cat > $TRAEFIK_DIR/config/crowdsec-config.yml << CROWDSEC
http:
  middlewares:
    crowdsec-bouncer:
      plugin:
        crowdsec-bouncer:
          enabled: true
          apiURL: http://localhost:8080/
          apiKey: \${CROWDSEC_API_KEY}
          defaultDecision: allow

    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true

tls:
  options:
    default:
      minVersion: VersionTLS12
      sniStrict: true
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
CROWDSEC

# Create Traefik static configuration
cat > $TRAEFIK_DIR/config/traefik.yml << TRAEFIKCFG
log:
  level: INFO
  filePath: "/logs/traefik.log"

accessLog:
  filePath: "/logs/access.log"

api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy
  
  file:
    directory: "/config"
    watch: true

certificatesResolvers:
  dnschallenge:
    acme:
      email: "${LETSENCRYPT_EMAIL}"
      storage: "/data/acme.json"
      dnsChallenge:
        provider: "${DNS_PROVIDER}"
        delayBeforeCheck: 30
TRAEFIKCFG

# Get CrowdSec API key if CrowdSec is installed
if command -v cscli &> /dev/null; then
  echo "CrowdSec is installed, checking for bouncer..."
  if ! cscli bouncers list | grep -q "traefik-bouncer"; then
    echo "Creating CrowdSec bouncer for Traefik..."
    CROWDSEC_API_KEY=$(cscli bouncers add traefik-bouncer -o raw)
    echo "Created bouncer with API key: $CROWDSEC_API_KEY"
  else
    echo "CrowdSec bouncer already exists, retrieving API key..."
    CROWDSEC_API_KEY=$(cscli bouncers list -o json | jq -r '.[] | select(.name=="traefik-bouncer") | .api_key')
  fi
  
  # Allow hyperglass and traefik in CrowdSec
  cscli decisions add --ip $ANYCAST_IPV4 --type bypass --duration 8760h
  cscli decisions add --ip $ANYCAST_IPV6 --type bypass --duration 8760h
  echo "Added CrowdSec bypass decisions for anycast IPs"
else
  echo "CrowdSec not found, skipping integration"
  CROWDSEC_API_KEY="not-configured"
  # Modify Traefik config to disable CrowdSec
  sed -i 's/enabled: true/enabled: false/' $TRAEFIK_DIR/config/crowdsec-config.yml
fi

# Create docker-compose.yml for Traefik
cat > $TRAEFIK_DIR/docker-compose.yml << TRAEFIK
services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    ports:
      - "${ANYCAST_IPV4}:80:80"
      - "${ANYCAST_IPV4}:443:443"
      - "[${ANYCAST_IPV6}]:80:80"
      - "[${ANYCAST_IPV6}]:443:443"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${TRAEFIK_DIR}/config:/config:ro
      - ${TRAEFIK_DIR}/data:/data
      - ${TRAEFIK_DIR}/logs:/logs
    environment:
      - CROWDSEC_API_KEY=${CROWDSEC_API_KEY}
      - DNSMADEEASY_API_KEY=${DNS_API_KEY}
      - DNSMADEEASY_API_SECRET=${DNS_API_SECRET}
    command:
      - "--configfile=/config/traefik.yml"
    labels:
      - "traefik.enable=true"
      # Dashboard
      - "traefik.http.routers.traefik.rule=Host(\`traefik.${DOMAIN}\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=dnschallenge"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.middlewares=crowdsec-bouncer,admin-auth"
      - "traefik.http.middlewares.admin-auth.basicauth.users=admin:${HASHED_PASSWORD}"

networks:
  proxy:
    name: proxy
    external: false
TRAEFIK

echo "[7] Creating Hyperglass configuration..."
mkdir -p $DEST_DIR
cd $DEST_DIR

# Create docker-compose.yml
cat > docker-compose.yml << DOCKER
services:
  hyperglass:
    image: ghcr.io/thatmattlove/hyperglass:latest
    container_name: hyperglass
    restart: unless-stopped
    networks:
      - proxy
    expose:
      - 8080
    volumes:
      - ./hyperglass.yaml:/app/hyperglass.yaml:ro
      - hyperglass_data:/app/data
    labels:
      - "traefik.enable=true"
      # LG subdomain
      - "traefik.http.routers.hyperglass-sub.rule=Host(\`lg.${DOMAIN}\`)"
      - "traefik.http.routers.hyperglass-sub.entrypoints=websecure"
      - "traefik.http.routers.hyperglass-sub.tls.certresolver=dnschallenge"
      - "traefik.http.routers.hyperglass-sub.middlewares=crowdsec-bouncer"
      # Service config
      - "traefik.http.services.hyperglass.loadbalancer.server.port=8080"

volumes:
  hyperglass_data:

networks:
  proxy:
    name: proxy
    external: false
DOCKER

# Get server info
HOSTNAME=$(hostname)
REGION=$(hostname | cut -d'-' -f1)
MAIN_IP=$(hostname -I | awk '{print $1}')

# Create hyperglass.yaml
cat > hyperglass.yaml << CONFIG
hyperglass:
  debug: false
  developer_mode: false
  listen_address: 0.0.0.0
  listen_port: 8080
  log_level: warning
  docs: true
  external_link_mode: icon
  external_link_icon: external-link
  legacy_api: false
  private_asn: false
  cache_timeout: 600

general:
  primary_asn: ${OUR_AS:-27218}
  org_name: "Infinitum Nihil BGP Anycast"
  filter: false
  credit: true
  limit:
    ipv4: 24
    ipv6: 64
  google_analytics:
    enabled: false

web:
  title: "BGP Looking Glass"
  subtitle: "View BGP routing information"
  greeting: "Network visibility with BIRD 2.16.2"
  title_mode: separate
  favicon: null
  logo: null
  text:
    bgp_aspath: "AS Path"
    bgp_community: "BGP Community"
    bgp_route: "BGP Route"
    ping: "Ping"
    traceroute: "Traceroute"
  text_size: md
  theme:
    colors:
      primary: '#0098FF'
      secondary: '#00CC88'
      background: '#fff'
      black: '#000'
      white: '#fff'
      dark:
        100: '#e6e6e6'
        200: '#cccccc'
        300: '#b3b3b3'
        400: '#999999'
        500: '#808080'
        600: '#666666'
        700: '#4d4d4d'
        800: '#333333'
        900: '#1a1a1a'
    font:
      sans: 'Inter'
    radius: md

routers:
  - name: "bird-local"
    address: "localhost"
    network: "Local BGP"
    location: "$REGION"
    asn: ${OUR_AS:-27218}
    port: 179
    credential:
      username: null
      password: null
    type: bird2
    ignore_version: true
    proxy: false

commands:
  bgp_route:
    default: true
    ipv4:
      bird2: "show route for {target} all"
    ipv6:
      bird2: "show route for {target} all"
  bgp_community:
    default: true
    ipv4:
      bird2: "show route where community ~ [{target}] all"
    ipv6:
      bird2: "show route where community ~ [{target}] all"
  bgp_aspath:
    default: true
    ipv4:
      bird2: "show route where bgp_path ~ [{target}] all"
    ipv6:
      bird2: "show route where bgp_path ~ [{target}] all"
  ping:
    default: true
    ipv4:
      command: "ping -c 5 -w 5 {target}"
    ipv6: 
      command: "ping6 -c 5 -w 5 {target}"
  traceroute:
    default: true
    ipv4:
      command: "traceroute -w 1 -q 1 -n {target}"
    ipv6:
      command: "traceroute6 -w 1 -q 1 -n {target}"

messages:
  no_output: "Command completed, but returned no output."
  authentication:
    failed: "Authentication failed."
    timeout: "Authentication timed out."
  connection:
    timeout: "The connection timed out."
    refused: "The connection was refused."
    success: "The connection was successful, but something else went wrong."
CONFIG

# Create BIRD socket access script for hyperglass
cat > /usr/local/bin/hyperglass-bird << 'BIRDSCRIPT'
#!/bin/bash
# Script to proxy hyperglass commands to BIRD socket

BIRD_SOCKET="/var/run/bird/bird.ctl"

# Get command from stdin 
read -r command

# Pass to BIRD socket
echo "$command" | socat - UNIX-CONNECT:$BIRD_SOCKET
BIRDSCRIPT

chmod +x /usr/local/bin/hyperglass-bird

# Patch hyperglass configuration to use the script
sed -i 's|bird2: "show route for {target} all"|bird2: "/usr/local/bin/hyperglass-bird show route for {target} all"|g' hyperglass.yaml
sed -i 's|bird2: "show route where community ~ \\[{target}\\] all"|bird2: "/usr/local/bin/hyperglass-bird show route where community ~ [{target}] all"|g' hyperglass.yaml
sed -i 's|bird2: "show route where bgp_path ~ \\[{target}\\] all"|bird2: "/usr/local/bin/hyperglass-bird show route where bgp_path ~ [{target}] all"|g' hyperglass.yaml

echo "[8] Starting Traefik and Hyperglass with Docker Compose..."
# Start Traefik first
cd $TRAEFIK_DIR
docker compose down
docker compose pull
docker compose up -d

# Start Hyperglass
cd $DEST_DIR
docker compose down
docker compose pull
docker compose up -d

echo "[9] Verifying installations..."
echo "Checking Traefik container status:"
if docker ps | grep -q traefik; then
  echo "✅ Traefik is running"
  # Write success flag
  echo "TRAEFIK_RUNNING=true" > /tmp/hyperglass_status.env
else
  echo "❌ Traefik failed to start"
  echo "TRAEFIK_RUNNING=false" > /tmp/hyperglass_status.env
fi

echo "Checking Hyperglass container status:"
if docker ps | grep -q hyperglass; then
  echo "✅ Hyperglass is running"
  echo "HYPERGLASS_RUNNING=true" >> /tmp/hyperglass_status.env
else
  echo "❌ Hyperglass failed to start"
  echo "HYPERGLASS_RUNNING=false" >> /tmp/hyperglass_status.env
fi

echo "Testing BIRD socket proxy:"
if echo "show status" | /usr/local/bin/hyperglass-bird; then
  echo "✅ BIRD socket proxy is working"
  echo "BIRD_PROXY_WORKING=true" >> /tmp/hyperglass_status.env
else
  echo "❌ BIRD socket proxy failed"
  echo "BIRD_PROXY_WORKING=false" >> /tmp/hyperglass_status.env
fi

echo "IP Configuration:"
ip addr show dummy0

echo "Setup completed at $(date)"
PHASE2

# Create environment file with variables for phase 2
cat > /tmp/hyperglass_env.sh << ENVSH
#!/bin/bash
ANYCAST_IPV4="$ANYCAST_IPV4"
ANYCAST_IPV6="$ANYCAST_IPV6"
DOMAIN="$DOMAIN"
LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL"
OUR_AS="$OUR_AS"
DNS_PROVIDER="$DNS_PROVIDER"
DNS_API_KEY="$DNS_API_KEY"
DNS_API_SECRET="$DNS_API_SECRET"
TRAEFIK_ADMIN_PASSWORD="$TRAEFIK_ADMIN_PASSWORD"
HASHED_PASSWORD='$HASHED_PASSWORD'
DEST_DIR="/opt/hyperglass"
TRAEFIK_DIR="/opt/traefik"
CROWDSEC_API_KEY="not-configured"
ENVSH

# Make the phase 2 script executable
chmod +x /tmp/hyperglass_setup_phase2.sh
chmod +x /tmp/hyperglass_env.sh

# Enable the phase 2 service to run after reboot
systemctl enable hyperglass-setup-phase2.service

# Reboot the system
echo "System will restart in 5 seconds to apply network and Docker changes..."
echo "The script will continue automatically after reboot."
sync  # Ensure all disk writes are complete
sleep 5

# Force a reboot with multiple methods to ensure it happens
shutdown -r now || reboot || (echo "Manual reboot required" && exit 1)
EOF

  # Make the script executable
  chmod +x /tmp/hyperglass_setup.sh
  
  # Copy the script to the server
  echo "Copying installation script to $server_ip..."
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/hyperglass_setup.sh "root@$server_ip:/tmp/hyperglass_setup.sh"
  
  # Execute the script remotely
  echo "Executing installation script on $server_ip..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@$server_ip" "bash /tmp/hyperglass_setup.sh"
  
  # Check if we need to monitor the phase 2 installation
  echo "Waiting for server to reboot and continue with phase 2 installation..."
  sleep 20
  
  # Wait for phase 2 to complete
  MAX_RETRIES=60  # Increased from 30 to 60 (10 minutes total)
  RETRY_COUNT=0
  PHASE2_COMPLETED=false
  
  echo "Waiting for phase 2 to complete on $server_ip..."
  echo "This may take up to 10 minutes. Progress will be shown every 10 seconds."
  echo "----------------------------------------------------------------"
  
  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # First check if the server is even reachable
    if ! ping -c 1 -W 2 "$server_ip" > /dev/null 2>&1; then
      echo "Server $server_ip is still rebooting... ($(( $RETRY_COUNT + 1 ))/$MAX_RETRIES)"
    else
      # Server is up, check if Phase 2 completed
      if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" "root@$server_ip" "test -f /tmp/hyperglass_status.env && echo 'Phase 2 completed'" > /dev/null 2>&1; then
        PHASE2_COMPLETED=true
        echo "✅ Phase 2 completed successfully on $server_ip"
        break
      else
        # Check what's happening with Phase 2
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" "root@$server_ip" "if systemctl is-active --quiet hyperglass-setup-phase2.service; then echo '⏳ Phase 2 is actively running...'; elif [ -f /tmp/hyperglass_phase2.log ]; then echo '📋 Checking Phase 2 log...'; tail -3 /tmp/hyperglass_phase2.log; else echo '🔄 Waiting for Phase 2 to start...'; fi" 2>/dev/null || echo "Server is online but SSH connection failed"
      fi
    fi
    echo "Waiting for phase 2 installation to complete on $server_ip... ($(( $RETRY_COUNT + 1 ))/$MAX_RETRIES)"
    sleep 10
    RETRY_COUNT=$(( $RETRY_COUNT + 1 ))
  done
  
  if [ "$PHASE2_COMPLETED" = true ]; then
    # Get the installation status
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@$server_ip" "cat /tmp/hyperglass_status.env" > /tmp/hyperglass_status_${server_ip}.env
    source /tmp/hyperglass_status_${server_ip}.env
    
    if [ "$TRAEFIK_RUNNING" = "true" ] && [ "$HYPERGLASS_RUNNING" = "true" ] && [ "$BIRD_PROXY_WORKING" = "true" ]; then
      echo -e "${GREEN}✓ Hyperglass deployment completed successfully on $server_name ($server_ip)${RESET}"
    else
      echo -e "${YELLOW}⚠ Hyperglass deployment completed with issues on $server_name ($server_ip)${RESET}"
      [ "$TRAEFIK_RUNNING" != "true" ] && echo -e "${RED}  - Traefik is not running${RESET}"
      [ "$HYPERGLASS_RUNNING" != "true" ] && echo -e "${RED}  - Hyperglass is not running${RESET}"
      [ "$BIRD_PROXY_WORKING" != "true" ] && echo -e "${RED}  - BIRD socket proxy is not working${RESET}"
    fi
  else
    echo -e "${YELLOW}⚠ Could not verify phase 2 completion on $server_name ($server_ip)${RESET}"
    echo "You may need to check the server manually once it's back online."
  fi
  
  echo ""
}

# Deploy on all servers
deploy_hyperglass "$PRIMARY_IP" "Primary" "LAX"
deploy_hyperglass "$SECONDARY_IP" "Secondary" "EWR"
deploy_hyperglass "$TERTIARY_IP" "Tertiary" "MIA"
deploy_hyperglass "$QUATERNARY_IP" "Quaternary" "ORD"

# Add DNS records using DNSMadeEasy API
echo -e "${BOLD}Creating DNS records using DNSMadeEasy API...${RESET}"

# Calculate HMAC-SHA1 signature for DNSMadeEasy API
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REQUEST_BODY=""
HMAC_CONTENT="${TIMESTAMP}${REQUEST_BODY}"
HMAC_SIGNATURE=$(echo -n "${HMAC_CONTENT}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)

# Function to create/update DNS record
create_dns_record() {
  local HOSTNAME=$1
  local RECORD_TYPE=$2
  local VALUE=$3
  local TTL=300
  
  echo -e "Creating/updating DNS record: ${HOSTNAME} -> ${VALUE} (${RECORD_TYPE})"
  
  # First check if record exists
  RESPONSE=$(curl -s -X GET \
    -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
    -H "x-dnsme-requestDate: ${TIMESTAMP}" \
    -H "x-dnsme-hmac: ${HMAC_SIGNATURE}" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed/domainname/$DOMAIN/records?type=${RECORD_TYPE}&recordName=${HOSTNAME%%.$DOMAIN}")
  
  # Extract record ID if it exists
  RECORD_ID=$(echo $RESPONSE | grep -o '"id":[0-9]*' | grep -o '[0-9]*' | head -1)
  
  if [ -n "$RECORD_ID" ]; then
    # Record exists, update it
    echo "Record exists (ID: $RECORD_ID), updating..."
    curl -s -X PUT \
      -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
      -H "x-dnsme-requestDate: ${TIMESTAMP}" \
      -H "x-dnsme-hmac: ${HMAC_SIGNATURE}" \
      -H "Content-Type: application/json" \
      -d "{\"id\":${RECORD_ID}, \"name\":\"${HOSTNAME%%.$DOMAIN}\", \"type\":\"${RECORD_TYPE}\", \"value\":\"${VALUE}\", \"ttl\":${TTL}, \"gtdLocation\":\"DEFAULT\"}" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/domainname/$DOMAIN/records/${RECORD_ID}"
  else
    # Create new record
    echo "Record does not exist, creating..."
    curl -s -X POST \
      -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
      -H "x-dnsme-requestDate: ${TIMESTAMP}" \
      -H "x-dnsme-hmac: ${HMAC_SIGNATURE}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${HOSTNAME%%.$DOMAIN}\", \"type\":\"${RECORD_TYPE}\", \"value\":\"${VALUE}\", \"ttl\":${TTL}, \"gtdLocation\":\"DEFAULT\"}" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/domainname/$DOMAIN/records/"
  fi
  
  echo "Done"
}

# Create A records (IPv4) - only for subdomains
create_dns_record "lg.$DOMAIN" "A" "$ANYCAST_IPV4"
create_dns_record "traefik.$DOMAIN" "A" "$ANYCAST_IPV4"

# Create AAAA records (IPv6) - only for subdomains
create_dns_record "lg.$DOMAIN" "AAAA" "$ANYCAST_IPV6"
create_dns_record "traefik.$DOMAIN" "AAAA" "$ANYCAST_IPV6"

echo -e "${GREEN}All deployments complete!${RESET}"
echo ""
echo "Your hyperglass instance is now accessible at:"
echo "  - https://lg.infinitum-nihil.com"
echo ""
echo "Traefik dashboard is accessible at:"
echo "  - https://traefik.infinitum-nihil.com"
echo "  - Username: admin"
echo "  - Password: $TRAEFIK_ADMIN_PASSWORD"
echo ""
echo "Service details:"
echo "  - Anycast IPv4: $ANYCAST_IPV4"
echo "  - Anycast IPv6: $ANYCAST_IPV6"
echo "  - DNS records created automatically for the subdomains:"
echo "    * lg.infinitum-nihil.com"
echo "    * traefik.infinitum-nihil.com"
echo ""
echo "The service is running on all BGP servers with anycast routing."
echo "Traffic will be automatically directed to the closest available server."
echo ""
echo "Certificate issuance may take a few minutes to complete."
echo ""
echo "IMPORTANT: Make sure to save these credentials in a secure location:"
echo "  - Traefik Dashboard: admin / $TRAEFIK_ADMIN_PASSWORD"