#!/bin/bash
# Script to upgrade BGP speakers to 2GB RAM and deploy Hyperglass with Docker
# This script handles:
# 1. Upgrading all BGP speaker instances to 2GB RAM
# 2. Installing Docker and Docker Compose on all speakers
# 3. Setting up anycast IPs for the looking glass
# 4. Deploying Hyperglass with Docker on all speakers
# 5. Building Traefik from source for the reverse proxy

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
# Load API key from environment or .env file
if [ -f ".env" ]; then
    source .env
fi

if [ -z "$VULTR_API_KEY" ]; then
    echo "ERROR: VULTR_API_KEY not set. Set environment variable or create .env file"
    exit 1
fi
TRAEFIK_VERSION="v2.11.0"

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

# Function to check if an instance is already on 2GB plan
check_instance_size() {
  local server_ip=$1
  local server_name=$2
  
  echo -e "${BLUE}Checking $server_name server ($server_ip) size...${NC}"
  
  # Get the instance details
  local instance_info=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/instances" | \
    jq -r ".instances[] | select(.main_ip==\"$server_ip\")")
  
  if [ -z "$instance_info" ]; then
    echo -e "${RED}Failed to find instance for $server_name ($server_ip).${NC}"
    return 1
  fi
  
  # Extract the current plan
  local current_plan=$(echo "$instance_info" | jq -r ".plan")
  local server_status=$(echo "$instance_info" | jq -r ".server_status")
  local power_status=$(echo "$instance_info" | jq -r ".power_status")
  
  echo -e "${BLUE}Current plan: $current_plan${NC}"
  echo -e "${BLUE}Server status: $server_status${NC}"
  
  # Check if already 2GB or higher
  if [[ "$current_plan" == *"2gb"* || "$current_plan" == *"4gb"* || "$current_plan" == *"8gb"* ]]; then
    echo -e "${GREEN}Server $server_name is already on a 2GB or higher plan ($current_plan).${NC}"
    return 0
  else
    echo -e "${RED}Server $server_name is not on a 2GB or higher plan ($current_plan).${NC}"
    echo -e "${YELLOW}Please run /home/normtodd/birdbgp/resize_bgp_speakers.sh to resize the server.${NC}"
    return 1
  fi
}

# Function to install Docker on a server
install_docker() {
  local server_ip=$1
  local server_name=$2
  
  echo -e "${BLUE}Installing Docker on $server_name server ($server_ip)...${NC}"
  
  # Create a temporary script to install Docker
  cat > /tmp/install_docker.sh << 'EOT'
#!/bin/bash
set -e

# Update package list
apt-get update

# Install dependencies
apt-get install -y ca-certificates curl gnupg build-essential git make

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository to Apt sources
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package list again
apt-get update

# Install Docker Engine
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Create a symbolic link for docker-compose
ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose

# Verify Docker is installed correctly
docker --version
docker-compose --version

# Set up the dummy interface for anycast IPs if not already present
if ! ip link show dummy0 &> /dev/null; then
  echo "Setting up dummy0 interface for anycast IP..."
  modprobe dummy
  ip link add dummy0 type dummy
  ip link set dummy0 up
fi

# Add to /etc/modules to ensure it persists across reboots
if ! grep -q "dummy" /etc/modules; then
  echo "dummy" >> /etc/modules
fi

echo "Docker installation complete!"
EOT

  # Make the script executable
  chmod +x /tmp/install_docker.sh
  
  # Copy the script to the server and execute it
  scp -o StrictHostKeyChecking=no /tmp/install_docker.sh root@$server_ip:/tmp/
  ssh -o StrictHostKeyChecking=no root@$server_ip 'bash /tmp/install_docker.sh'
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully installed Docker on $server_name server.${NC}"
    return 0
  else
    echo -e "${RED}Failed to install Docker on $server_name server.${NC}"
    return 1
  fi
}

# Function to build Traefik from source
build_traefik() {
  local server_ip=$1
  local server_name=$2
  
  echo -e "${BLUE}Building Traefik from source on $server_name server ($server_ip)...${NC}"
  
  # Create a temporary script to build Traefik
  cat > /tmp/build_traefik.sh << EOT
#!/bin/bash
set -e

# Install Go if not already installed
if ! command -v go &> /dev/null; then
  echo "Installing Go..."
  wget https://go.dev/dl/go1.22.1.linux-amd64.tar.gz
  rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.1.linux-amd64.tar.gz
  export PATH=\$PATH:/usr/local/go/bin
  echo 'export PATH=\$PATH:/usr/local/go/bin' >> /root/.bashrc
fi

# Install additional dependencies
apt-get update
apt-get install -y git make gcc libc6-dev

# Clone Traefik repository
cd /tmp
rm -rf traefik
git clone https://github.com/traefik/traefik.git
cd traefik
git checkout $TRAEFIK_VERSION

# Build Traefik
echo "Building Traefik $TRAEFIK_VERSION..."
go mod download
make build

# Verify the build
./dist/traefik version

# Install to system
cp ./dist/traefik /usr/local/bin/
chmod +x /usr/local/bin/traefik

echo "Traefik build complete!"
EOT

  # Make the script executable
  chmod +x /tmp/build_traefik.sh
  
  # Copy the script to the server and execute it
  scp -o StrictHostKeyChecking=no /tmp/build_traefik.sh root@$server_ip:/tmp/
  ssh -o StrictHostKeyChecking=no root@$server_ip 'bash /tmp/build_traefik.sh'
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully built Traefik on $server_name server.${NC}"
    return 0
  else
    echo -e "${RED}Failed to build Traefik on $server_name server.${NC}"
    return 1
  fi
}

# Function to configure anycast IPs
configure_anycast() {
  local server_ip=$1
  local server_name=$2
  
  echo -e "${BLUE}Configuring anycast IPs on $server_name server ($server_ip)...${NC}"
  
  # Create a temporary script to configure anycast IPs
  cat > /tmp/configure_anycast.sh << EOT
#!/bin/bash
set -e

# Anycast IPs
ANYCAST_IPV4="$ANYCAST_IPV4"
ANYCAST_IPV6="$ANYCAST_IPV6"

# Ensure dummy0 interface exists
if ! ip link show dummy0 &> /dev/null; then
  echo "Setting up dummy0 interface..."
  modprobe dummy
  ip link add dummy0 type dummy
  ip link set dummy0 up
fi

# Configure anycast IPv4
echo "Configuring anycast IPv4: \$ANYCAST_IPV4..."
ip addr add \$ANYCAST_IPV4/32 dev dummy0 2>/dev/null || true

# Configure anycast IPv6
echo "Configuring anycast IPv6: \$ANYCAST_IPV6..."
ip -6 addr add \$ANYCAST_IPV6/128 dev dummy0 2>/dev/null || true

# Make configuration persistent
cat > /etc/networkd-dispatcher/routable.d/50-anycast-ip << EOF
#!/bin/bash
# Configure anycast IPs on dummy0 interface
ip addr add $ANYCAST_IPV4/32 dev dummy0 2>/dev/null || true
ip -6 addr add $ANYCAST_IPV6/128 dev dummy0 2>/dev/null || true
EOF

chmod +x /etc/networkd-dispatcher/routable.d/50-anycast-ip

# Create systemd service for persistent anycast IP configuration
cat > /etc/systemd/system/anycast-ip.service << EOF
[Unit]
Description=Configure Anycast IPs
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "ip addr add $ANYCAST_IPV4/32 dev dummy0 2>/dev/null || true; ip -6 addr add $ANYCAST_IPV6/128 dev dummy0 2>/dev/null || true"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable anycast-ip.service
systemctl start anycast-ip.service

# Verify configuration
echo "Verifying anycast IP configuration..."
ip addr show dummy0

echo "Anycast IP configuration complete!"
EOT

  # Make the script executable
  chmod +x /tmp/configure_anycast.sh
  
  # Copy the script to the server and execute it
  scp -o StrictHostKeyChecking=no /tmp/configure_anycast.sh root@$server_ip:/tmp/
  ssh -o StrictHostKeyChecking=no root@$server_ip 'bash /tmp/configure_anycast.sh'
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully configured anycast IPs on $server_name server.${NC}"
    return 0
  else
    echo -e "${RED}Failed to configure anycast IPs on $server_name server.${NC}"
    return 1
  fi
}

# Function to deploy Hyperglass
deploy_hyperglass() {
  local server_ip=$1
  local server_name=$2
  local lat=${LAT_COORDS[$server_name]}
  local lon=${LON_COORDS[$server_name]}
  local friendly_name=${FRIENDLY_NAMES[$server_name]}
  
  echo -e "${BLUE}Deploying Hyperglass on $server_name server ($server_ip)...${NC}"
  
  # Create directory structure
  ssh -o StrictHostKeyChecking=no root@$server_ip 'mkdir -p /etc/hyperglass'
  
  # Create a temporary script to set up Hyperglass
  cat > /tmp/deploy_hyperglass.sh << EOT
#!/bin/bash
set -e

# Configuration variables
DOMAIN="$DOMAIN"
SUBDOMAIN="$SUBDOMAIN"
SERVER_NAME="$server_name"
LAT="$lat"
LON="$lon"
FRIENDLY_NAME="$friendly_name"
LAX_IPV4="$LAX_IPV4"
EWR_IPV4="$EWR_IPV4"
MIA_IPV4="$MIA_IPV4"
ORD_IPV4="$ORD_IPV4"

# Create required directories
mkdir -p /etc/hyperglass
mkdir -p /etc/traefik
mkdir -p /etc/traefik/dynamic
mkdir -p /var/www/acme
mkdir -p /etc/hyperglass/data

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

# Create Traefik configuration
cat > /etc/traefik/traefik.yaml << 'EOF'
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
      email: "admin@$DOMAIN"
      storage: "/var/www/acme/acme.json"
      httpChallenge:
        entryPoint: web
EOF

# Create dynamic configuration for Traefik dashboard
cat > /etc/traefik/dynamic/dashboard.yaml << EOF
http:
  routers:
    dashboard:
      rule: "Host(\`traefik.$DOMAIN\`)"
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
          - "admin:$apr1$ruca84Hq$mbjdMZBAG.KWn7vfN/SNK/"  # admin:hyperglass
EOF

# Create Hyperglass configuration
cat > /etc/hyperglass/hyperglass.yaml << EOF
devices:
  - name: lax1
    display_name: "Los Angeles (LAX)"
    address: ${SERVER_NAME == "LAX" ? "localhost" : "$LAX_IPV4"}
    credential:
      type: ${SERVER_NAME == "LAX" ? "local_bird" : "http"}
      command: ${SERVER_NAME == "LAX" ? "/usr/local/bin/hyperglass-bird" : ""}
      base_url: ${SERVER_NAME == "LAX" ? "" : "http://$LAX_IPV4:8080"}
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
    address: ${SERVER_NAME == "EWR" ? "localhost" : "$EWR_IPV4"}
    credential:
      type: ${SERVER_NAME == "EWR" ? "local_bird" : "http"}
      command: ${SERVER_NAME == "EWR" ? "/usr/local/bin/hyperglass-bird" : ""}
      base_url: ${SERVER_NAME == "EWR" ? "" : "http://$EWR_IPV4:8080"}
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
    address: ${SERVER_NAME == "MIA" ? "localhost" : "$MIA_IPV4"}
    credential:
      type: ${SERVER_NAME == "MIA" ? "local_bird" : "http"}
      command: ${SERVER_NAME == "MIA" ? "/usr/local/bin/hyperglass-bird" : ""}
      base_url: ${SERVER_NAME == "MIA" ? "" : "http://$MIA_IPV4:8080"}
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
    address: ${SERVER_NAME == "ORD" ? "localhost" : "$ORD_IPV4"}
    credential:
      type: ${SERVER_NAME == "ORD" ? "local_bird" : "http"}
      command: ${SERVER_NAME == "ORD" ? "/usr/local/bin/hyperglass-bird" : ""}
      base_url: ${SERVER_NAME == "ORD" ? "" : "http://$ORD_IPV4:8080"}
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
  You are currently connected to our **$FRIENDLY_NAME** node.
  
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

logo_url: "https://bimi.infinitum-nihil.com/image/logo.svg"

ui:
  title: "27218 Infinitum Nihil LG"
  theme:
    colors:
      primary: "#0064c1"
      secondary: "#00c187"
    text:
      light: "#ffffff"
      dark: "#444444"
EOF

# Create Docker Compose file
cat > /root/docker-compose.yml << EOF
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
EOF

# Create systemd service for Docker Compose
cat > /etc/systemd/system/hyperglass.service << 'EOF'
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
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable hyperglass.service
systemctl start hyperglass.service

echo "Hyperglass deployment complete!"
echo "Access your looking glass at https://$SUBDOMAIN.$DOMAIN"
EOT

  # Make the script executable
  chmod +x /tmp/deploy_hyperglass.sh
  
  # Copy the script to the server and execute it
  scp -o StrictHostKeyChecking=no /tmp/deploy_hyperglass.sh root@$server_ip:/tmp/
  ssh -o StrictHostKeyChecking=no root@$server_ip 'bash /tmp/deploy_hyperglass.sh'
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully deployed Hyperglass on $server_name server.${NC}"
    return 0
  else
    echo -e "${RED}Failed to deploy Hyperglass on $server_name server.${NC}"
    return 1
  fi
}

# Function to secure Hyperglass API access
secure_hyperglass_access() {
  local server_ip=$1
  local server_name=$2
  local other_ips=()
  
  # Create a list of all other BGP node IPs (excluding the current node)
  for ip in "${SERVER_IPS[@]}"; do
    if [ "$ip" != "$server_ip" ]; then
      other_ips+=("$ip")
    fi
  done
  
  echo -e "${BLUE}Securing Hyperglass API access on $server_name server ($server_ip)...${NC}"
  
  # Create a temporary script to secure Hyperglass API access
  cat > /tmp/secure_hyperglass_access.sh << EOT
#!/bin/bash
set -e

# First, ensure UFW is installed and active
apt-get update
apt-get install -y ufw

# Check if UFW is already enabled
if ! ufw status | grep -q "Status: active"; then
  echo "Enabling UFW..."
  echo "y" | ufw enable
fi

# Delete any existing rules for port 8080
ufw status numbered | grep 8080 | awk '{print \$1}' | sed 's/\]//' | sort -r | xargs -I {} ufw --force delete {}

# Block all access to port 8080 by default
echo "Blocking all access to port 8080 by default..."
ufw deny 8080/tcp

# Allow access from other BGP nodes only
echo "Allowing access from other BGP nodes only..."
EOT

  # Add rules for each other BGP node
  for other_ip in "${other_ips[@]}"; do
    echo "ufw allow from $other_ip to any port 8080 proto tcp comment 'Allow Hyperglass API from BGP node'" >> /tmp/secure_hyperglass_access.sh
  done
  
  # Add verification steps to the script
  cat >> /tmp/secure_hyperglass_access.sh << 'EOT'
# Reload UFW to apply changes
ufw reload

# Show the UFW status
echo "UFW status for port 8080:"
ufw status | grep 8080

# Verify Docker container port binding
echo "Docker port binding:"
docker ps --format "{{.Names}}: {{.Ports}}" | grep hyperglass

echo "Hyperglass API access secured successfully!"
EOT

  # Make the script executable
  chmod +x /tmp/secure_hyperglass_access.sh
  
  # Copy the script to the server and execute it
  scp -o StrictHostKeyChecking=no /tmp/secure_hyperglass_access.sh root@$server_ip:/tmp/
  ssh -o StrictHostKeyChecking=no root@$server_ip 'bash /tmp/secure_hyperglass_access.sh'
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully secured Hyperglass API access on $server_name server.${NC}"
    return 0
  else
    echo -e "${RED}Failed to secure Hyperglass API access on $server_name server.${NC}"
    return 1
  fi
}

# Main execution flow
echo -e "${MAGENTA}=== BGP Speaker Upgrade and Hyperglass Deployment ===${NC}"
echo -e "${BLUE}This script will upgrade all BGP speakers to 2GB RAM and install Docker and Hyperglass.${NC}"
echo -e "${BLUE}Servers to be upgraded:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  echo -e "  ${CYAN}${SERVER_NAMES[$i]}:${NC} ${SERVER_IPS[$i]}"
done
echo

# Process each server
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  
  echo -e "${MAGENTA}=== Processing $SERVER_NAME server ($SERVER_IP) ===${NC}"
  
  # Step 1: Check if the instance is already on 2GB plan
  if check_instance_size "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ $SERVER_NAME server is ready with 2GB RAM.${NC}"
  else
    echo -e "${RED}✗ $SERVER_NAME server needs to be resized to 2GB RAM first.${NC}"
    echo -e "${YELLOW}Skipping this server...${NC}"
    continue
  fi
  
  # Step 2: Install Docker
  if install_docker "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully installed Docker on $SERVER_NAME server.${NC}"
  else
    echo -e "${RED}✗ Failed to install Docker on $SERVER_NAME server.${NC}"
    echo -e "${YELLOW}Skipping remaining steps for this server...${NC}"
    continue
  fi
  
  # Step 3: Configure anycast IPs
  if configure_anycast "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully configured anycast IPs on $SERVER_NAME server.${NC}"
  else
    echo -e "${RED}✗ Failed to configure anycast IPs on $SERVER_NAME server.${NC}"
    echo -e "${YELLOW}Skipping remaining steps for this server...${NC}"
    continue
  fi
  
  # Step 4: Build Traefik from source (commented out for now, using Docker image)
  # if build_traefik "$SERVER_IP" "$SERVER_NAME"; then
  #   echo -e "${GREEN}✓ Successfully built Traefik on $SERVER_NAME server.${NC}"
  # else
  #   echo -e "${RED}✗ Failed to build Traefik on $SERVER_NAME server.${NC}"
  #   echo -e "${YELLOW}Using Docker image for Traefik instead...${NC}"
  # fi
  
  # Step 5: Deploy Hyperglass
  if deploy_hyperglass "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully deployed Hyperglass on $SERVER_NAME server.${NC}"
  else
    echo -e "${RED}✗ Failed to deploy Hyperglass on $SERVER_NAME server.${NC}"
    echo -e "${YELLOW}Continuing with next server...${NC}"
    continue
  fi
  
  # Step 6: Secure Hyperglass API access
  if secure_hyperglass_access "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully secured Hyperglass API access on $SERVER_NAME server.${NC}"
  else
    echo -e "${RED}✗ Failed to secure Hyperglass API access on $SERVER_NAME server.${NC}"
    echo -e "${YELLOW}Continuing with next server...${NC}"
  fi
  
  echo -e "${GREEN}=== Completed processing $SERVER_NAME server ===${NC}"
  echo
done

echo -e "${MAGENTA}=== Deployment Summary ===${NC}"
echo -e "${BLUE}The looking glass should now be accessible at:${NC} ${GREEN}https://$SUBDOMAIN.$DOMAIN${NC}"
echo -e "${BLUE}It may take a few minutes for DNS to propagate and Let's Encrypt certificates to be issued.${NC}"
echo -e "${BLUE}Anycast routing will direct users to their closest BGP speaker automatically.${NC}"
echo
echo -e "${GREEN}Deployment complete!${NC}"