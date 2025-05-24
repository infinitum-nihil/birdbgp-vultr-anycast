#!/bin/bash
# Script to update Hyperglass configuration on all BGP speakers
# This script should be run after the upgrade_and_deploy_hyperglass.sh script

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

# Function to download the logo
download_logo() {
  local server_ip=$1
  local server_name=$2
  
  echo -e "${BLUE}Downloading logo to $server_name server ($server_ip)...${NC}"
  
  # Create a temporary script to download the logo
  cat > /tmp/download_logo.sh << EOT
#!/bin/bash
set -e

# Configuration variables
LOGO_URL="$LOGO_URL"

# Create directories if they don't exist
mkdir -p /etc/hyperglass/static/images

# Download the logo
curl -s "$LOGO_URL" -o /etc/hyperglass/static/images/logo.svg

# Create a PNG version if needed
if command -v convert &> /dev/null; then
  convert /etc/hyperglass/static/images/logo.svg /etc/hyperglass/static/images/logo.png
  echo "Created PNG version of the logo"
else
  echo "ImageMagick not installed, skipping PNG conversion"
fi

echo "Logo downloaded successfully"
EOT

  # Make the script executable
  chmod +x /tmp/download_logo.sh
  
  # Copy the script to the server and execute it
  scp -o StrictHostKeyChecking=no /tmp/download_logo.sh root@$server_ip:/tmp/
  ssh -o StrictHostKeyChecking=no root@$server_ip 'bash /tmp/download_logo.sh'
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully downloaded logo on $server_name server.${NC}"
    return 0
  else
    echo -e "${RED}Failed to download logo on $server_name server.${NC}"
    return 1
  fi
}

# Function to update Hyperglass configuration
update_hyperglass_config() {
  local server_ip=$1
  local server_name=$2
  local lat=${LAT_COORDS[$server_name]}
  local lon=${LON_COORDS[$server_name]}
  local friendly_name=${FRIENDLY_NAMES[$server_name]}
  
  echo -e "${BLUE}Updating Hyperglass configuration on $server_name server ($server_ip)...${NC}"
  
  # Create a temporary script to update the Hyperglass configuration
  cat > /tmp/update_hyperglass_config.sh << EOT
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

# Install imagemagick if needed for logo conversion
apt-get update && apt-get install -y imagemagick || true

# Update Hyperglass configuration
cat > /etc/hyperglass/hyperglass.yaml << EOF
---
debug: false

logging:
  directory: /var/log/hyperglass
  format: text
  level: info
  max_size: 10
  retention: 14
  syslog: false

redis:
  host: redis
  port: 6379
  database: 0
  timeout: 2
  ttl: 3600
  show_cache: true

docs:
  enable: true
  layout: swagger
  path: /api/docs

web:
  title: "27218 Infinitum Nihil LG"
  meta_description: "BGP Looking Glass for AS27218 Infinitum Nihil Network"
  primary_asn: 27218
  info_text: |
    # Welcome to the AS27218 Infinitum Nihil Looking Glass
    
    This service provides real-time visibility into our global BGP routing infrastructure.
    You are currently connected to our **$FRIENDLY_NAME** node.
    
    ## Network Information
    - **ASN**: 27218
    - **Network**: Infinitum Nihil, LLC
    - **IPv4**: 192.30.120.0/23
    - **IPv6**: 2620:71:4000::/48
  logo: 
    src: /static/images/logo.svg
    width: 75
    height: 75
  credit: true
  external_link:
    enable: true
    title: "Visit our website"
    url: https://infinitum-nihil.com
  peering_policy_url: https://infinitum-nihil.com/peering
  theme:
    colors:
      primary: "#0064c1"
      secondary: "#00c187"
    text:
      light: "#ffffff"
      dark: "#444444"

site_title: "27218 Infinitum Nihil LG"
org_name: "Infinitum Nihil, LLC"
base_url: https://lg.infinitum-nihil.com

server:
  host: 0.0.0.0
  port: 8001
  protocol: http
  workers: 2
  cors_origins:
    - https://$SUBDOMAIN.$DOMAIN
  request_timeout: 90
  listen_timeout: 180
  query_timeout: 180
  response_timeout: 180

messages:
  no_output: "Command did not return any output."
  connection_error: "Connection to device failed."
  authentication_error: "Authentication to device failed."
  timeout: "The request timed out."
  config_error: "A configuration error occurred."
  operational_error: "An operational error occurred."
  not_implemented: "This feature is not yet implemented."
  no_input: "No input was provided."
  invalid_field: "Invalid input field."
  general_error: "An error occurred while processing your request."
  feature_not_enabled: "This feature is not enabled."

devices:
  - name: lax1
    address: ${SERVER_NAME == "LAX" ? "localhost" : "$LAX_IPV4"}
    display_name: "Los Angeles (LAX)"
    network: "Infinitum Nihil"
    location:
      lat: ${LAT_COORDS["LAX"]}
      lon: ${LON_COORDS["LAX"]}
    credential:
      type: ${SERVER_NAME == "LAX" ? "local_bird" : "http"}
      command: ${SERVER_NAME == "LAX" ? "/usr/local/bin/bird-proxy" : ""}
      base_url: ${SERVER_NAME == "LAX" ? "" : "http://$LAX_IPV4:8001"}
    commands:
      - bgp_route
      - bgp_community
      - bgp_aspath
      - ping
      - traceroute
    bgp_route:
      enabled: true
    bgp_community:
      enabled: true
    bgp_aspath:
      enabled: true
    ping:
      enabled: true
      vrf:
        4: default
        6: default
    traceroute:
      enabled: true
      vrf:
        4: default
        6: default
  
  - name: ewr1
    address: ${SERVER_NAME == "EWR" ? "localhost" : "$EWR_IPV4"}
    display_name: "New Jersey (EWR)"
    network: "Infinitum Nihil"
    location:
      lat: ${LAT_COORDS["EWR"]}
      lon: ${LON_COORDS["EWR"]}
    credential:
      type: ${SERVER_NAME == "EWR" ? "local_bird" : "http"}
      command: ${SERVER_NAME == "EWR" ? "/usr/local/bin/bird-proxy" : ""}
      base_url: ${SERVER_NAME == "EWR" ? "" : "http://$EWR_IPV4:8001"}
    commands:
      - bgp_route
      - bgp_community
      - bgp_aspath
      - ping
      - traceroute
    bgp_route:
      enabled: true
    bgp_community:
      enabled: true
    bgp_aspath:
      enabled: true
    ping:
      enabled: true
      vrf:
        4: default
        6: default
    traceroute:
      enabled: true
      vrf:
        4: default
        6: default
        
  - name: mia1
    address: ${SERVER_NAME == "MIA" ? "localhost" : "$MIA_IPV4"}
    display_name: "Miami (MIA)"
    network: "Infinitum Nihil"
    location:
      lat: ${LAT_COORDS["MIA"]}
      lon: ${LON_COORDS["MIA"]}
    credential:
      type: ${SERVER_NAME == "MIA" ? "local_bird" : "http"}
      command: ${SERVER_NAME == "MIA" ? "/usr/local/bin/bird-proxy" : ""}
      base_url: ${SERVER_NAME == "MIA" ? "" : "http://$MIA_IPV4:8001"}
    commands:
      - bgp_route
      - bgp_community
      - bgp_aspath
      - ping
      - traceroute
    bgp_route:
      enabled: true
    bgp_community:
      enabled: true
    bgp_aspath:
      enabled: true
    ping:
      enabled: true
      vrf:
        4: default
        6: default
    traceroute:
      enabled: true
      vrf:
        4: default
        6: default
        
  - name: ord1
    address: ${SERVER_NAME == "ORD" ? "localhost" : "$ORD_IPV4"}
    display_name: "Chicago (ORD)"
    network: "Infinitum Nihil"
    location:
      lat: ${LAT_COORDS["ORD"]}
      lon: ${LON_COORDS["ORD"]}
    credential:
      type: ${SERVER_NAME == "ORD" ? "local_bird" : "http"}
      command: ${SERVER_NAME == "ORD" ? "/usr/local/bin/bird-proxy" : ""}
      base_url: ${SERVER_NAME == "ORD" ? "" : "http://$ORD_IPV4:8001"}
    commands:
      - bgp_route
      - bgp_community
      - bgp_aspath
      - ping
      - traceroute
    bgp_route:
      enabled: true
    bgp_community:
      enabled: true
    bgp_aspath:
      enabled: true
    ping:
      enabled: true
      vrf:
        4: default
        6: default
    traceroute:
      enabled: true
      vrf:
        4: default
        6: default

cache:
  enabled: true
  timeout: 3600
  custom_timeout:
    bgp_route: 300
    bgp_community: 600
    bgp_aspath: 600
    ping: 30
    traceroute: 30
EOF

# Update Docker Compose file to ensure API access between nodes
cat > /root/docker-compose.yml << EOF
version: '3.8'

networks:
  traefik-net:
    name: traefik-net

services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/traefik:/etc/traefik
      - /var/www/acme:/var/www/acme
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      
  redis:
    image: redis:7-alpine
    container_name: redis
    restart: always
    networks:
      - traefik-net
    volumes:
      - redis-data:/data
    command: redis-server --save 60 1 --loglevel warning
    
  hyperglass:
    image: python:3.12-alpine
    container_name: hyperglass
    restart: always
    networks:
      - traefik-net
    ports:
      - "8001:8001"  # Expose to other nodes
    volumes:
      - /etc/hyperglass:/etc/hyperglass
      - /var/run/bird:/var/run/bird
      - /usr/local/bin/bird-proxy:/usr/local/bin/bird-proxy
    depends_on:
      - redis
    command: >
      sh -c "pip install --no-cache-dir hyperglass[all]==1.0.5 requests &&
             hyperglass setup -n &&
             hyperglass start"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hyperglass.rule=Host(\`$SUBDOMAIN.$DOMAIN\`)"
      - "traefik.http.routers.hyperglass.entrypoints=websecure"
      - "traefik.http.routers.hyperglass.tls=true"
      - "traefik.http.routers.hyperglass.tls.certresolver=letsencrypt"
      - "traefik.http.services.hyperglass.loadbalancer.server.port=8001"

volumes:
  redis-data:
EOF

# Ensure the inbound access for port 8001 (for inter-node communication)
ufw allow 8001/tcp comment "Allow Hyperglass API between nodes"

# Restart the containers
cd /root
docker-compose down
docker-compose up -d

echo "Hyperglass configuration updated on $SERVER_NAME server!"
EOT

  # Make the script executable
  chmod +x /tmp/update_hyperglass_config.sh
  
  # Copy the script to the server and execute it
  scp -o StrictHostKeyChecking=no /tmp/update_hyperglass_config.sh root@$server_ip:/tmp/
  ssh -o StrictHostKeyChecking=no root@$server_ip 'bash /tmp/update_hyperglass_config.sh'
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully updated Hyperglass configuration on $server_name server.${NC}"
    return 0
  else
    echo -e "${RED}Failed to update Hyperglass configuration on $server_name server.${NC}"
    return 1
  fi
}

# Main execution flow
echo -e "${MAGENTA}=== Hyperglass Configuration Update ===${NC}"
echo -e "${BLUE}This script will update the Hyperglass configuration on all BGP speakers.${NC}"
echo -e "${BLUE}Servers to be updated:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  echo -e "  ${CYAN}${SERVER_NAMES[$i]}:${NC} ${SERVER_IPS[$i]}"
done
echo

# Process each server
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  
  echo -e "${MAGENTA}=== Processing $SERVER_NAME server ($SERVER_IP) ===${NC}"
  
  # Step 1: Download logo
  if download_logo "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully downloaded logo on $SERVER_NAME server.${NC}"
  else
    echo -e "${RED}✗ Failed to download logo on $SERVER_NAME server.${NC}"
    echo -e "${YELLOW}Continuing with configuration update...${NC}"
  fi
  
  # Step 2: Update Hyperglass configuration
  if update_hyperglass_config "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully updated Hyperglass configuration on $SERVER_NAME server.${NC}"
  else
    echo -e "${RED}✗ Failed to update Hyperglass configuration on $SERVER_NAME server.${NC}"
  fi
  
  echo -e "${GREEN}=== Completed processing $SERVER_NAME server ===${NC}"
  echo
done

echo -e "${MAGENTA}=== Configuration Update Summary ===${NC}"
echo -e "${BLUE}The looking glass is accessible at:${NC} ${GREEN}https://$SUBDOMAIN.$DOMAIN${NC}"
echo -e "${BLUE}All configurations have been updated with:${NC}"
echo -e "  ${CYAN}- Base URL set to https://$SUBDOMAIN.$DOMAIN${NC}"
echo -e "  ${CYAN}- Site title set to '27218 Infinitum Nihil LG'${NC}"
echo -e "  ${CYAN}- Logo set to $LOGO_URL${NC}"
echo -e "  ${CYAN}- API documentation enabled at /api/docs${NC}"
echo -e "  ${CYAN}- Inter-node communication configured via HTTP API${NC}"
echo -e "  ${CYAN}- All nodes configured to access each other's BGP data${NC}"
echo -e "${BLUE}Anycast routing will direct users to their closest BGP speaker automatically.${NC}"
echo
echo -e "${GREEN}Configuration update complete!${NC}"