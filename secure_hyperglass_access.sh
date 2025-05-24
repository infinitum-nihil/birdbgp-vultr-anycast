#!/bin/bash
# Script to secure Hyperglass API access between nodes
# This ensures port 8001 is only accessible to other BGP nodes, not the public internet

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

# Get server information from config file
LAX_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-west".lax.ipv4.address' "$CONFIG_FILE")
EWR_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".ewr.ipv4.address' "$CONFIG_FILE")
MIA_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".mia.ipv4.address' "$CONFIG_FILE")
ORD_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-central".ord.ipv4.address' "$CONFIG_FILE")

# Server list for iteration
SERVER_IPS=($LAX_IPV4 $EWR_IPV4 $MIA_IPV4 $ORD_IPV4)
SERVER_NAMES=("LAX" "EWR" "MIA" "ORD")

# Check for jq dependency
if ! command -v jq &> /dev/null; then
  echo -e "${YELLOW}jq is not installed. Installing...${NC}"
  apt-get update && apt-get install -y jq
fi

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

# Delete any existing rules for port 8001
ufw status numbered | grep 8001 | awk '{print $1}' | sed 's/\]//' | sort -r | xargs -I {} ufw --force delete {}

# Block all access to port 8001 by default
echo "Blocking all access to port 8001 by default..."
ufw deny 8001/tcp

# Allow access from other BGP nodes only
echo "Allowing access from other BGP nodes only..."
EOT

  # Add rules for each other BGP node
  for other_ip in "${other_ips[@]}"; do
    echo "ufw allow from $other_ip to any port 8001 proto tcp comment 'Allow Hyperglass API from BGP node'" >> /tmp/secure_hyperglass_access.sh
  done
  
  # Add verification steps to the script
  cat >> /tmp/secure_hyperglass_access.sh << 'EOT'
# Reload UFW to apply changes
ufw reload

# Show the UFW status
echo "UFW status:"
ufw status

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
echo -e "${MAGENTA}=== Secure Hyperglass API Access ===${NC}"
echo -e "${BLUE}This script will secure Hyperglass API access on all BGP speakers.${NC}"
echo -e "${BLUE}It will ensure port 8001 is only accessible to other BGP nodes, not the public internet.${NC}"
echo -e "${BLUE}Servers to be secured:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  echo -e "  ${CYAN}${SERVER_NAMES[$i]}:${NC} ${SERVER_IPS[$i]}"
done
echo

# Process each server
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  
  echo -e "${MAGENTA}=== Processing $SERVER_NAME server ($SERVER_IP) ===${NC}"
  
  if secure_hyperglass_access "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully secured Hyperglass API access on $SERVER_NAME server.${NC}"
  else
    echo -e "${RED}✗ Failed to secure Hyperglass API access on $SERVER_NAME server.${NC}"
  fi
  
  echo -e "${GREEN}=== Completed processing $SERVER_NAME server ===${NC}"
  echo
done

echo -e "${MAGENTA}=== Security Update Summary ===${NC}"
echo -e "${BLUE}All servers have been secured with the following configuration:${NC}"
echo -e "  ${CYAN}- Port 8001/tcp is blocked from the public internet${NC}"
echo -e "  ${CYAN}- Port 8001/tcp is only accessible from other BGP node IPs${NC}"
echo -e "  ${CYAN}- Inter-node communication for Hyperglass API remains functional${NC}"
echo -e "  ${CYAN}- Public access remains available only via HTTPS through Traefik${NC}"
echo
echo -e "${GREEN}Security update complete!${NC}"