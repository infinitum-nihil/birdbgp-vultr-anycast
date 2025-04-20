#!/bin/bash
# Script to deploy hyperglass using direct GitHub repo rather than NPM package

# Source environment variables
source "$(dirname "$0")/.env"

# Set LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Anycast IPs
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"

# Domain and DNS settings
DOMAIN="${DOMAIN:-infinitum-nihil.com}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-ssl@$DOMAIN}"

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"

echo -e "${BOLD}Hyperglass GitHub Deployment to LAX BGP Speaker${RESET}"
echo "======================================="
echo -e "LAX Server IP: ${LAX_IP}"
echo -e "Anycast IPs: ${ANYCAST_IPV4} and ${ANYCAST_IPV6}"
echo -e "Domain: ${DOMAIN}"
echo -e "Let's Encrypt email: ${LETSENCRYPT_EMAIL}"
echo "======================================="

# Generate a secure password for Traefik dashboard
TRAEFIK_ADMIN_PASSWORD=$(openssl rand -base64 12 2>/dev/null || echo "SecureTraefikAdmin")
HASHED_PASSWORD=$(htpasswd -nb admin "$TRAEFIK_ADMIN_PASSWORD" | sed -e s/\\$/\\$\\$/g)

# Create the deployment script to run on the remote server
cat > /tmp/hyperglass_github_setup.sh << 'EOF'
#!/bin/bash
set -e

# Load variables from the environment file
if [ -f "/tmp/server_env" ]; then
  source "/tmp/server_env"
else
  echo "Error: Missing server environment file"
  exit 1
fi

# Configuration variables
ANYCAST_IPV4="${ANYCAST_IPV4}"
ANYCAST_IPV6="${ANYCAST_IPV6}"
DOMAIN="${DOMAIN}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"
TRAEFIK_ADMIN_PASSWORD="${TRAEFIK_ADMIN_PASSWORD}"
HASHED_PASSWORD="${HASHED_PASSWORD}"
DEST_DIR="/opt/hyperglass"
TRAEFIK_DIR="/opt/traefik"
CONFIG_DIR="/etc/hyperglass"

# Set noninteractive mode to avoid prompts
export DEBIAN_FRONTEND=noninteractive

echo "[1] Updating system packages..."
apt update && DEBIAN_FRONTEND=noninteractive apt upgrade -y

echo "[2] Installing prerequisites..."
# Pre-configure iptables-persistent to automatically accept saving rules
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

# Install required packages
DEBIAN_FRONTEND=noninteractive apt install -y apt-transport-https ca-certificates curl software-properties-common git socat python3 python3-pip iptables-persistent netfilter-persistent jq apache2-utils make

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
# Create dummy interface if not exists
if ! ip link show dummy0 &>/dev/null; then
  echo "Creating dummy0 interface"
  modprobe dummy
  ip link add dummy0 type dummy
  ip link set dummy0 up
  echo "dummy" > /etc/modules-load.d/dummy.conf
fi

# Add anycast IPs to dummy interface
ip addr add $ANYCAST_IPV4/32 dev dummy0 2>/dev/null || echo "IPv4 anycast IP already exists"
ip -6 addr add $ANYCAST_IPV6/128 dev dummy0 2>/dev/null || echo "IPv6 anycast IP already exists"

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
        - $ANYCAST_IPV4/32
        - $ANYCAST_IPV6/128
NETPLAN

# Copy with correct permissions to the final location
install -m 0600 -o root -g root /tmp/60-anycast.yaml /etc/netplan/60-anycast.yaml

# Apply network config
netplan apply || echo "netplan apply had non-zero exit code"

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

echo "[6] Creating Traefik configuration..."
# Create Traefik directory
mkdir -p $TRAEFIK_DIR/data $TRAEFIK_DIR/config $TRAEFIK_DIR/logs

# Create acme.json with correct permissions
touch $TRAEFIK_DIR/data/acme.json
chmod 600 $TRAEFIK_DIR/data/acme.json

# Create Traefik dynamic configuration
cat > $TRAEFIK_DIR/config/dynamic.yml << DYNAMIC
http:
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true
    admin-auth:
      basicAuth:
        users:
          - "$HASHED_PASSWORD"

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
DYNAMIC

# Create Traefik static configuration
cat > $TRAEFIK_DIR/config/traefik.yml << STATIC
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
  letsencrypt:
    acme:
      email: "$LETSENCRYPT_EMAIL"
      storage: "/data/acme.json"
      httpChallenge:
        entryPoint: web
STATIC

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
    command:
      - "--configfile=/config/traefik.yml"
    labels:
      - "traefik.enable=true"
      # Dashboard
      - "traefik.http.routers.traefik.rule=Host(\`traefik.${DOMAIN}\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.middlewares=admin-auth"

networks:
  proxy:
    name: proxy
    external: false
TRAEFIK

echo "[7] Setting up Hyperglass from GitHub..."
# Clean up any existing installation
rm -rf $DEST_DIR
mkdir -p $DEST_DIR $CONFIG_DIR
cd $DEST_DIR

# Clone the GitHub repository
echo "Cloning Hyperglass repository from GitHub..."
git clone https://github.com/thatmattlove/hyperglass .

# Create the enhanced BIRD socket access script
cat > /usr/local/bin/hyperglass-bird << 'BIRDSCRIPT'
#!/bin/bash
# Enhanced script to proxy hyperglass commands to BIRD socket

BIRD_SOCKET="/var/run/bird/bird.ctl"

if [ ! -S "$BIRD_SOCKET" ]; then
  echo "Error: BIRD socket not found at $BIRD_SOCKET"
  exit 1
fi

# Get command from stdin
read -r command

# Pass to BIRD socket with error handling
echo "$command" | socat -t 5 - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null || 
  echo "Error: Failed to connect to BIRD socket"
BIRDSCRIPT

chmod +x /usr/local/bin/hyperglass-bird

# Get server info
HOSTNAME=$(hostname)
REGION=$(hostname | cut -d'-' -f1)
MAIN_IP=$(hostname -I | awk '{print $1}')

# Create hyperglass.yaml configuration
cat > $CONFIG_DIR/hyperglass.yaml << CONFIG
---
hyperglass:
  listen_address: 0.0.0.0
  listen_port: 8001
  secret_key: $(openssl rand -hex 32)
  developer_mode: false
  debug: false
  log_level: info
  primary_asn: 27218

ui:
  text:
    title: "BGP Looking Glass"
    subtitle: "Infinitum Nihil BGP Anycast"
    info:
      pre_heading: "Network Information"
      heading: "Infinitum Nihil BGP Anycast"
    no_results: "No results found"
  colors:
    button: "#0098FF"
    title: "#0098FF"
    subtitle: "#00CC88"

queries:
  bgp_route:
    enable: true
    ipv4_limit: 24
    ipv6_limit: 64
  bgp_aspath:
    enable: true
  bgp_community:
    enable: true
  ping:
    enable: true
  traceroute:
    enable: true
CONFIG

# Create devices.yaml
cat > $CONFIG_DIR/devices.yaml << DEVICES
---
# Bird2 Router Configuration
${REGION}-bgp:
  address: localhost
  asn: 27218
  credential:
    password: null
    username: null
  location: "$REGION"
  network: "Infinitum Nihil BGP"
  port: 179
  proxy: false
  type: bird2
  commands:
    bgp_route:
      ipv4: "/usr/local/bin/hyperglass-bird 'show route for {target} all'"
      ipv6: "/usr/local/bin/hyperglass-bird 'show route for {target} all'"
    bgp_community:
      ipv4: "/usr/local/bin/hyperglass-bird 'show route where community ~ [{target}] all'"
      ipv6: "/usr/local/bin/hyperglass-bird 'show route where community ~ [{target}] all'"
    bgp_aspath:
      ipv4: "/usr/local/bin/hyperglass-bird 'show route where bgp_path ~ [{target}] all'" 
      ipv6: "/usr/local/bin/hyperglass-bird 'show route where bgp_path ~ [{target}] all'"
DEVICES

# Make sure config directory has correct permissions
chown -R root:root $CONFIG_DIR
chmod -R 755 $CONFIG_DIR

# Create docker-compose.yml for hyperglass using image from GitHub container registry
cat > $DEST_DIR/docker-compose.yml << DOCKER
services:
  hyperglass:
    image: ghcr.io/thatmattlove/hyperglass:latest
    container_name: hyperglass
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8001:8001"
    volumes:
      - $CONFIG_DIR:/etc/hyperglass:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hyperglass-sub.rule=Host(\`lg.${DOMAIN}\`)"
      - "traefik.http.routers.hyperglass-sub.entrypoints=websecure"
      - "traefik.http.routers.hyperglass-sub.tls.certresolver=letsencrypt"
      - "traefik.http.services.hyperglass.loadbalancer.server.port=8001"
    environment:
      - HYPERGLASS_CONFIG_DIR=/etc/hyperglass

networks:
  proxy:
    name: proxy
    external: false
DOCKER

echo "[8] Starting Traefik and Hyperglass with Docker Compose..."
# Start Traefik first
cd $TRAEFIK_DIR
docker compose down
docker compose pull
docker compose up -d

# Try running hyperglass using docker-compose
cd $DEST_DIR
docker compose down
docker compose pull
docker compose up -d

# If the GitHub Container Registry image fails, try alternative approaches
if ! docker ps | grep -q hyperglass; then
  echo "GitHub Container Registry image failed, trying to build locally..."
  
  # Try to build the Hyperglass image locally
  cd $DEST_DIR
  
  # Remove the old compose file
  rm docker-compose.yml
  
  # Create a new compose file that builds from local source
  cat > docker-compose.yml << LOCALDOCKER
services:
  hyperglass:
    build: .
    container_name: hyperglass
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8001:8001"
    volumes:
      - $CONFIG_DIR:/etc/hyperglass:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hyperglass-sub.rule=Host(\`lg.${DOMAIN}\`)"
      - "traefik.http.routers.hyperglass-sub.entrypoints=websecure"
      - "traefik.http.routers.hyperglass-sub.tls.certresolver=letsencrypt"
      - "traefik.http.services.hyperglass.loadbalancer.server.port=8001"
    environment:
      - HYPERGLASS_CONFIG_DIR=/etc/hyperglass

networks:
  proxy:
    external: true
LOCALDOCKER

  # Try to build and run with the local source
  docker compose down
  docker compose build
  docker compose up -d
fi

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
  echo "✅ Hyperglass is running in Docker"
  echo "HYPERGLASS_RUNNING=true" >> /tmp/hyperglass_status.env
  echo "HYPERGLASS_MODE=docker" >> /tmp/hyperglass_status.env
else
  echo "❌ Hyperglass failed to start in Docker"
  echo "HYPERGLASS_RUNNING=false" >> /tmp/hyperglass_status.env
  echo "Check Docker logs for errors:"
  docker compose logs
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
EOF

# Create a file with environment variables for the server
cat > /tmp/server_env << ENV
ANYCAST_IPV4=${ANYCAST_IPV4}
ANYCAST_IPV6=${ANYCAST_IPV6}
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
TRAEFIK_ADMIN_PASSWORD=${TRAEFIK_ADMIN_PASSWORD}
HASHED_PASSWORD='${HASHED_PASSWORD}'
ENV

# Make the script executable
chmod +x /tmp/hyperglass_github_setup.sh

# Deploy to LAX server
deploy_to_lax() {
  echo -e "${BOLD}Deploying to LAX server (${LAX_IP})...${RESET}"
  
  # Copy the files to the server
  echo "Copying files to ${LAX_IP}..."
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/hyperglass_github_setup.sh "root@${LAX_IP}:/tmp/hyperglass_github_setup.sh"
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/server_env "root@${LAX_IP}:/tmp/server_env"
  
  # Execute the script remotely
  echo "Executing installation script on ${LAX_IP}..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@${LAX_IP}" "bash /tmp/hyperglass_github_setup.sh"
  
  # Check the installation status
  echo "Checking installation status..."
  sleep 5  # Give containers time to start
  
  # Check if traefik is running
  TRAEFIK_RUNNING=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@${LAX_IP}" "docker ps | grep -w traefik || echo 'not running'")
  
  # Try different methods of checking hyperglass status
  HYPERGLASS_RUNNING=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@${LAX_IP}" "docker ps | grep -w hyperglass || echo 'not running'")
  
  if [[ "$TRAEFIK_RUNNING" != *"not running"* ]]; then
    echo -e "${GREEN}✓ Traefik is running successfully on ${LAX_IP}${RESET}"
    TRAEFIK_SUCCESS=true
  else
    echo -e "${RED}✗ Traefik failed to start${RESET}"
    TRAEFIK_SUCCESS=false
  fi
  
  if [[ "$HYPERGLASS_RUNNING" != *"not running"* ]]; then
    echo -e "${GREEN}✓ Hyperglass is running successfully on ${LAX_IP}${RESET}"
    HYPERGLASS_SUCCESS=true
  else
    echo -e "${RED}✗ Hyperglass failed to start${RESET}"
    # Try to diagnose the issue
    echo "Checking Docker logs for hyperglass container:"
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@${LAX_IP}" "docker logs hyperglass || echo 'No container logs available'"
    HYPERGLASS_SUCCESS=false
  fi
  
  if [ "$TRAEFIK_SUCCESS" = true ]; then
    echo ""
    echo "Your hyperglass instance is now accessible at:"
    echo "  - https://lg.${DOMAIN}"
    echo ""
    echo "Traefik dashboard is accessible at:"
    echo "  - https://traefik.${DOMAIN}"
    echo "  - Username: admin"
    echo "  - Password: $TRAEFIK_ADMIN_PASSWORD"
  else
    echo -e "${RED}✗ Deployment had issues. Please check the server manually.${RESET}"
  fi
}

# Run the deployment
deploy_to_lax

echo -e "${GREEN}Deployment process completed.${RESET}"