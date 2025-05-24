#!/bin/bash
# Script to deploy Hyperglass on all BGP speakers
# This is a simplified version focused on successful deployment

set -e

# ANSI color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
CONFIG_FILE="/home/normtodd/birdbgp/config_files/config.json"
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"
DOMAIN="infinitum-nihil.com"
SUBDOMAIN="lg"
LOGO_URL="https://bimi.infinitum-nihil.com/image/logo.svg"

# Get server information from config file
LAX_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-west".lax.ipv4.address' "$CONFIG_FILE")
EWR_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".ewr.ipv4.address' "$CONFIG_FILE")
MIA_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".mia.ipv4.address' "$CONFIG_FILE")
ORD_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-central".ord.ipv4.address' "$CONFIG_FILE")

# Server list for iteration
SERVER_IPS=($LAX_IPV4 $EWR_IPV4 $MIA_IPV4 $ORD_IPV4)
SERVER_NAMES=("LAX" "EWR" "MIA" "ORD")

# Location coordinates for each server
declare -A LAT_COORDS
declare -A LON_COORDS
declare -A FRIENDLY_NAMES

LAT_COORDS["LAX"]="34.0522"
LON_COORDS["LAX"]="-118.2437"
FRIENDLY_NAMES["LAX"]="Los Angeles"

LAT_COORDS["EWR"]="40.6895"
LON_COORDS["EWR"]="-74.1745"
FRIENDLY_NAMES["EWR"]="New Jersey"

LAT_COORDS["MIA"]="25.7617"
LON_COORDS["MIA"]="-80.1918"
FRIENDLY_NAMES["MIA"]="Miami"

LAT_COORDS["ORD"]="41.8781"
LON_COORDS["ORD"]="-87.6298"
FRIENDLY_NAMES["ORD"]="Chicago"

# Check for jq dependency
if ! command -v jq &> /dev/null; then
  echo -e "${YELLOW}jq is not installed. Installing...${NC}"
  apt-get update && apt-get install -y jq
fi

# Function to create the deployment script for a specific server
create_deployment_script() {
  local server_name=$1
  local lat=${LAT_COORDS[$server_name]}
  local lon=${LON_COORDS[$server_name]}
  local friendly_name=${FRIENDLY_NAMES[$server_name]}
  local script_path="/tmp/deploy_hyperglass_${server_name,,}.sh"
  
  echo "Creating deployment script for $server_name at $script_path..."
  
  cat > "$script_path" << EOF
#!/bin/bash
set -e

# Configuration variables
DOMAIN="$DOMAIN"
SUBDOMAIN="$SUBDOMAIN"
SERVER_NAME="$server_name"
FRIENDLY_NAME="$friendly_name"
LAX_IPV4="$LAX_IPV4"
EWR_IPV4="$EWR_IPV4"
MIA_IPV4="$MIA_IPV4"
ORD_IPV4="$ORD_IPV4"
LAT="$lat"
LON="$lon"

echo "Starting Hyperglass deployment on \$SERVER_NAME..."

# Create required directories
mkdir -p /etc/hyperglass
mkdir -p /etc/traefik
mkdir -p /etc/traefik/dynamic
mkdir -p /var/www/acme
mkdir -p /etc/hyperglass/data

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg build-essential git make
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose || true
fi

# Create BIRD socket proxy script
cat > /usr/local/bin/hyperglass-bird << 'EOS'
#!/bin/bash
BIRD_SOCKET="/var/run/bird/bird.ctl"
# Find BIRD socket if not at the default location
if [ ! -S "\$BIRD_SOCKET" ]; then
  FOUND_SOCKET=\$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
  if [ -n "\$FOUND_SOCKET" ]; then
    BIRD_SOCKET="\$FOUND_SOCKET"
  fi
fi
# Get command from stdin
read -r command
# Pass to BIRD socket using socat
echo "\$command" | socat - UNIX-CONNECT:\$BIRD_SOCKET
EOS

chmod +x /usr/local/bin/hyperglass-bird

# Set BIRD socket permissions
BIRD_SOCKET=\$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
if [ -S "\$BIRD_SOCKET" ]; then
  echo "Found BIRD socket at \$BIRD_SOCKET"
  chmod 666 "\$BIRD_SOCKET"
  # Create a symlink to a standard location
  mkdir -p /var/run/bird
  ln -sf "\$BIRD_SOCKET" /var/run/bird/bird.ctl
  chmod 666 /var/run/bird/bird.ctl
fi

# Configure anycast IPs if needed
if ! ip addr show dummy0 2>/dev/null | grep -q "$ANYCAST_IPV4"; then
  echo "Configuring anycast IPv4..."
  modprobe dummy || true
  ip link add dummy0 type dummy 2>/dev/null || true
  ip link set dummy0 up
  ip addr add $ANYCAST_IPV4/32 dev dummy0 2>/dev/null || true
  ip -6 addr add $ANYCAST_IPV6/128 dev dummy0 2>/dev/null || true
  
  # Make configuration persistent
  cat > /etc/systemd/system/anycast-ip.service << EOSVC
[Unit]
Description=Configure Anycast IPs
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "ip link add dummy0 type dummy 2>/dev/null || true; ip link set dummy0 up; ip addr add $ANYCAST_IPV4/32 dev dummy0 2>/dev/null || true; ip -6 addr add $ANYCAST_IPV6/128 dev dummy0 2>/dev/null || true"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOSVC

  systemctl daemon-reload
  systemctl enable anycast-ip.service
  systemctl start anycast-ip.service
  
  # Ensure dummy module loads at boot
  echo "dummy" >> /etc/modules
fi

# Create Traefik configuration
cat > /etc/traefik/traefik.yaml << EOF1
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: "INFO"

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
  file:
    directory: "/etc/traefik/dynamic"
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "admin@\$DOMAIN"
      storage: "/var/www/acme/acme.json"
      httpChallenge:
        entryPoint: web
EOF1

# Create dynamic configuration for Traefik dashboard
cat > /etc/traefik/dynamic/dashboard.yaml << EOF2
http:
  routers:
    dashboard:
      rule: "Host(\`traefik.\$DOMAIN\`)"
      service: "api@internal"
      entryPoints:
        - "websecure"
      middlewares:
        - auth
      tls:
        certResolver: letsencrypt

  middlewares:
    auth:
      basicAuth:
        users:
          - "admin:\\$apr1\\$ruca84Hq\\$mbjdMZBAG.KWn7vfN/SNK/"  # admin:hyperglass
EOF2

# Download logo
mkdir -p /etc/hyperglass/static/images
curl -s "$LOGO_URL" -o /etc/hyperglass/static/images/logo.svg

# Create Hyperglass configuration
if [ "\$SERVER_NAME" = "LAX" ]; then
  LAX_CREDENTIAL_TYPE="subprocess"
  LAX_COMMAND="/usr/local/bin/hyperglass-bird"
  LAX_BASE_URL=""
else
  LAX_CREDENTIAL_TYPE="http"
  LAX_COMMAND=""
  LAX_BASE_URL="http://$LAX_IPV4:8080"
fi

if [ "\$SERVER_NAME" = "EWR" ]; then
  EWR_CREDENTIAL_TYPE="subprocess"
  EWR_COMMAND="/usr/local/bin/hyperglass-bird"
  EWR_BASE_URL=""
else
  EWR_CREDENTIAL_TYPE="http"
  EWR_COMMAND=""
  EWR_BASE_URL="http://$EWR_IPV4:8080"
fi

if [ "\$SERVER_NAME" = "MIA" ]; then
  MIA_CREDENTIAL_TYPE="subprocess"
  MIA_COMMAND="/usr/local/bin/hyperglass-bird"
  MIA_BASE_URL=""
else
  MIA_CREDENTIAL_TYPE="http"
  MIA_COMMAND=""
  MIA_BASE_URL="http://$MIA_IPV4:8080"
fi

if [ "\$SERVER_NAME" = "ORD" ]; then
  ORD_CREDENTIAL_TYPE="subprocess"
  ORD_COMMAND="/usr/local/bin/hyperglass-bird"
  ORD_BASE_URL=""
else
  ORD_CREDENTIAL_TYPE="http"
  ORD_COMMAND=""
  ORD_BASE_URL="http://$ORD_IPV4:8080"
fi

cat > /etc/hyperglass/hyperglass.yaml << EOF3
devices:
  - name: lax1
    display_name: "Los Angeles (LAX)"
    address: localhost
    credential:
      type: subprocess
      command: /usr/local/bin/hyperglass-bird
    platform: bird
    network: "Infinitum Nihil"
    location:
      lat: ${LAT_COORDS["LAX"]}
      lon: ${LON_COORDS["LAX"]}
    vrf:
      - name: default
        display_name: "Global Table"
        ipv4:
          source: $LAX_IPV4
        ipv6:
          source: "2001:19f0:6001:48e4:5400:2ff:fe9a:1c2e"
    
  - name: ewr1
    display_name: "New Jersey (EWR)"
    address: $EWR_IPV4
    credential:
      type: http
      base_url: http://$EWR_IPV4:8080
    platform: bird
    network: "Infinitum Nihil"
    location:
      lat: ${LAT_COORDS["EWR"]}
      lon: ${LON_COORDS["EWR"]}
    vrf:
      - name: default
        display_name: "Global Table"
        ipv4:
          source: $EWR_IPV4
        ipv6:
          source: "2001:19f0:7:2b32:5400:2ff:fe9a:1c3e"
    
  - name: mia1
    display_name: "Miami (MIA)"
    address: $MIA_IPV4
    credential:
      type: http
      base_url: http://$MIA_IPV4:8080
    platform: bird
    network: "Infinitum Nihil"
    location:
      lat: ${LAT_COORDS["MIA"]}
      lon: ${LON_COORDS["MIA"]}
    vrf:
      - name: default
        display_name: "Global Table"
        ipv4:
          source: $MIA_IPV4
        ipv6:
          source: "2001:19f0:9001:2bb2:5400:2ff:fe9a:1c4f"
    
  - name: ord1
    display_name: "Chicago (ORD)"
    address: $ORD_IPV4
    credential:
      type: http
      base_url: http://$ORD_IPV4:8080
    platform: bird
    network: "Infinitum Nihil"
    location:
      lat: ${LAT_COORDS["ORD"]}
      lon: ${LON_COORDS["ORD"]}
    vrf:
      - name: default
        display_name: "Global Table"
        ipv4:
          source: $ORD_IPV4
        ipv6:
          source: "2001:19f0:5c01:24a8:5400:2ff:fe9a:1c5a"

docs:
  enable: true

asn: 27218
org_name: "Infinitum Nihil, LLC"
site_title: "27218 Infinitum Nihil LG"
site_description: "BGP Looking Glass for AS27218 Infinitum Nihil Network"
base_url: "https://$SUBDOMAIN.$DOMAIN"

cache:
  timeout: 3600
  custom_timeout:
    bgp_route: 300
    bgp_community: 600
    bgp_aspath: 600
    ping: 30
    traceroute: 30

info_title: "Welcome to the AS27218 Infinitum Nihil Looking Glass"
info_text: |
  This service provides real-time visibility into our global BGP routing infrastructure.
  You are currently connected to our **\$FRIENDLY_NAME** node.
  
  ## Network Information
  - **ASN**: 27218
  - **Network**: Infinitum Nihil, LLC
  - **IPv4**: 192.30.120.0/23
  - **IPv6**: 2620:71:4000::/48

hyperglass:
  debug: false
  listen_address: 0.0.0.0
  listen_port: 8080
  log_level: info
  external_link_mode: icon
  cache_timeout: 600

logo_url: "$LOGO_URL"

ui:
  title: "27218 Infinitum Nihil LG"
  theme:
    colors:
      primary: "#0064c1"
      secondary: "#00c187"
    text:
      light: "#ffffff"
      dark: "#444444"
EOF3

# Create Docker Compose file
cat > /root/docker-compose.yml << EOF4
version: '3.8'

networks:
  proxy:
    name: proxy

services:
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/traefik:/etc/traefik
      - /var/www/acme:/var/www/acme
    command:
      - "--configfile=/etc/traefik/traefik.yaml"
    
  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    networks:
      - proxy
    volumes:
      - redis-data:/data
    command: redis-server --save 60 1 --loglevel warning
    
  hyperglass:
    image: ghcr.io/thatmattlove/hyperglass:latest
    container_name: hyperglass
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8080:8080"  # Expose to other nodes
    volumes:
      - /etc/hyperglass/hyperglass.yaml:/app/hyperglass.yaml:ro
      - /etc/hyperglass/data:/app/data
      - /usr/local/bin/hyperglass-bird:/usr/local/bin/hyperglass-bird:ro
      - /var/run/bird:/var/run/bird
    depends_on:
      - redis
    environment:
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hyperglass.rule=Host(\`$SUBDOMAIN.$DOMAIN\`)"
      - "traefik.http.routers.hyperglass.entrypoints=websecure"
      - "traefik.http.routers.hyperglass.tls=true"
      - "traefik.http.routers.hyperglass.tls.certresolver=letsencrypt"
      - "traefik.http.services.hyperglass.loadbalancer.server.port=8080"

volumes:
  redis-data:
EOF4

# Create systemd service for Docker Compose
cat > /etc/systemd/system/hyperglass.service << 'EOF5'
[Unit]
Description=Hyperglass Looking Glass
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/root
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF5

# Secure API access - block public access to port 8080
apt-get update
apt-get install -y ufw
if ! ufw status | grep -q "Status: active"; then
  echo "y" | ufw enable
fi

# Delete any existing rules for port 8080
ufw status numbered | grep 8080 | awk '{print \$1}' | sed 's/\]//' | sort -r | xargs -I {} ufw --force delete {} || true

# Block all access to port 8080 by default
ufw deny 8080/tcp

# Allow access from other BGP nodes
ufw allow from $LAX_IPV4 to any port 8080 proto tcp comment "Allow Hyperglass API from LAX"
ufw allow from $EWR_IPV4 to any port 8080 proto tcp comment "Allow Hyperglass API from EWR"
ufw allow from $MIA_IPV4 to any port 8080 proto tcp comment "Allow Hyperglass API from MIA"
ufw allow from $ORD_IPV4 to any port 8080 proto tcp comment "Allow Hyperglass API from ORD"

# Reload UFW
ufw reload

# Enable and start the service
systemctl daemon-reload
systemctl enable hyperglass.service
systemctl start hyperglass.service

# Check if containers are running
docker ps

echo "Hyperglass deployment complete on \$SERVER_NAME server!"
echo "Access your looking glass at https://$SUBDOMAIN.$DOMAIN"
EOF

  chmod +x "$script_path"
  echo "Script created at $script_path"
  return 0
}

# Function to deploy to a server
deploy_to_server() {
  local server_ip=$1
  local server_name=$2
  local script_path="/tmp/deploy_hyperglass_${server_name,,}.sh"
  
  echo -e "${MAGENTA}=== Deploying to $server_name server ($server_ip) ===${NC}"
  
  # Copy the script to the server
  scp -o StrictHostKeyChecking=no "$script_path" root@$server_ip:/tmp/
  
  # Execute the script
  ssh -o StrictHostKeyChecking=no root@$server_ip "bash /tmp/deploy_hyperglass_${server_name,,}.sh"
  
  local status=$?
  if [ $status -eq 0 ]; then
    echo -e "${GREEN}✓ Successfully deployed Hyperglass on $server_name server.${NC}"
  else
    echo -e "${RED}✗ Failed to deploy Hyperglass on $server_name server (exit code $status).${NC}"
  fi
  
  echo -e "${GREEN}=== Completed deployment to $server_name server ===${NC}"
  echo
  return $status
}

# Main execution flow
echo -e "${MAGENTA}=== Hyperglass Deployment to BGP Speakers ===${NC}"
echo -e "${BLUE}This script will deploy Hyperglass to all BGP speakers.${NC}"
echo -e "${BLUE}Servers to deploy to:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  echo -e "  ${CYAN}${SERVER_NAMES[$i]}:${NC} ${SERVER_IPS[$i]}"
done
echo

# First, create deployment scripts for all servers
for i in "${!SERVER_IPS[@]}"; do
  SERVER_NAME=${SERVER_NAMES[$i]}
  create_deployment_script "$SERVER_NAME"
done

# Process each server
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  deploy_to_server "$SERVER_IP" "$SERVER_NAME"
done

echo -e "${MAGENTA}=== Deployment Summary ===${NC}"
echo -e "${BLUE}The looking glass should now be accessible at:${NC} ${GREEN}https://$SUBDOMAIN.$DOMAIN${NC}"
echo -e "${BLUE}It may take a few minutes for DNS to propagate and Let's Encrypt certificates to be issued.${NC}"
echo -e "${BLUE}Anycast routing will direct users to their closest BGP speaker automatically.${NC}"
echo
echo -e "${GREEN}Deployment complete!${NC}"