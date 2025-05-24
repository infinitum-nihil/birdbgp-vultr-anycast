#!/bin/bash
# Script to directly resize Vultr instances to 2GB RAM

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
# Load API key from environment or .env file
if [ -f ".env" ]; then
    source .env
fi

if [ -z "$VULTR_API_KEY" ]; then
    echo "ERROR: VULTR_API_KEY not set. Set environment variable or create .env file"
    exit 1
fi

# Get server information from config file
LAX_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-west".lax.ipv4.address' "$CONFIG_FILE")
EWR_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".ewr.ipv4.address' "$CONFIG_FILE")
MIA_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".mia.ipv4.address' "$CONFIG_FILE")
ORD_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-central".ord.ipv4.address' "$CONFIG_FILE")

# Server list for iteration
SERVER_IPS=($LAX_IPV4 $EWR_IPV4 $MIA_IPV4 $ORD_IPV4)
SERVER_NAMES=("LAX" "EWR" "MIA" "ORD")

# Check for required tools
if ! command -v jq &> /dev/null; then
  echo -e "${YELLOW}jq is not installed. Installing...${NC}"
  apt-get update && apt-get install -y jq
fi

if ! command -v curl &> /dev/null; then
  echo -e "${YELLOW}curl is not installed. Installing...${NC}"
  apt-get update && apt-get install -y curl
fi

# First, let's list all instances to see what we're working with
echo -e "${BLUE}Listing all Vultr instances...${NC}"
curl -s -H "Authorization: Bearer $VULTR_API_KEY" "https://api.vultr.com/v2/instances" | jq -r '.instances[] | "\(.id) \(.label) \(.main_ip) \(.plan) \(.ram)"'

# Function to resize an instance
resize_instance() {
  local server_ip=$1
  local server_name=$2
  
  echo -e "${BLUE}Resizing $server_name server ($server_ip) to 2GB RAM...${NC}"
  
  # First, get the instance ID using the IP address
  local instance_info=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" "https://api.vultr.com/v2/instances" | jq -r ".instances[] | select(.main_ip==\"$server_ip\") | \"\(.id) \(.label) \(.plan)\"")
  
  if [ -z "$instance_info" ]; then
    echo -e "${RED}Failed to find instance ID for $server_name ($server_ip).${NC}"
    
    # Try alternate method - list all instances and let user identify the correct one
    echo -e "${YELLOW}Listing all instances for manual identification...${NC}"
    local all_instances=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" "https://api.vultr.com/v2/instances" | jq -r ".instances[] | \"\(.id) \(.label) \(.main_ip) \(.plan)\"")
    echo "$all_instances"
    
    echo -e "${YELLOW}Please enter the instance ID for $server_name:${NC}"
    read -r instance_id
    
    if [ -z "$instance_id" ]; then
      echo -e "${RED}No instance ID provided. Skipping $server_name.${NC}"
      return 1
    fi
  else
    instance_id=$(echo "$instance_info" | cut -d' ' -f1)
    current_plan=$(echo "$instance_info" | cut -d' ' -f3)
    
    echo -e "${GREEN}Found instance ID: $instance_id${NC}"
    echo -e "${BLUE}Current plan: $current_plan${NC}"
    
    # Check if already 2GB or higher
    if [[ "$current_plan" == *"2gb"* || "$current_plan" == *"4gb"* || "$current_plan" == *"8gb"* ]]; then
      echo -e "${GREEN}Server $server_name is already on a 2GB or higher plan ($current_plan). No resize needed.${NC}"
      return 0
    fi
  fi
  
  # 2GB RAM plan on Vultr is vc2-2c-2gb
  echo -e "${BLUE}Upgrading instance to 2GB plan...${NC}"
  local upgrade_response=$(curl -s -X PATCH \
    -H "Authorization: Bearer $VULTR_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"plan":"vc2-2c-2gb"}' \
    "https://api.vultr.com/v2/instances/$instance_id")
  
  # Check if the upgrade was successful
  # Note: Vultr API returns an empty response on success for this endpoint
  if [ -z "$upgrade_response" ]; then
    echo -e "${GREEN}Successfully initiated resize for $server_name server.${NC}"
    echo -e "${YELLOW}Waiting for resize to complete...${NC}"
    echo -e "${YELLOW}Note: The server may reboot during this process.${NC}"
    sleep 10
    
    # Check instance status
    echo -e "${BLUE}Checking instance status...${NC}"
    local status=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" "https://api.vultr.com/v2/instances/$instance_id" | jq -r ".instance.status")
    echo -e "${BLUE}Current status: $status${NC}"
    
    if [ "$status" == "resizing" ] || [ "$status" == "pending" ]; then
      echo -e "${YELLOW}Resize operation in progress. This might take several minutes.${NC}"
      echo -e "${YELLOW}Please check the server status later using:${NC}"
      echo -e "${YELLOW}curl -s -H \"Authorization: Bearer $VULTR_API_KEY\" \"https://api.vultr.com/v2/instances/$instance_id\" | jq -r \".instance.status\"${NC}"
    elif [ "$status" == "active" ]; then
      echo -e "${GREEN}Server appears to be active. Resize might be complete or pending reboot.${NC}"
    else
      echo -e "${YELLOW}Server status: $status${NC}"
    fi
    
    return 0
  else
    echo -e "${RED}Failed to resize $server_name server.${NC}"
    echo -e "${RED}API Response: $upgrade_response${NC}"
    return 1
  fi
}

# Main execution flow
echo -e "${MAGENTA}=== BGP Speaker Resize to 2GB RAM ===${NC}"
echo -e "${BLUE}This script will resize all BGP speakers to 2GB RAM.${NC}"
echo -e "${BLUE}Servers to be resized:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  echo -e "  ${CYAN}${SERVER_NAMES[$i]}:${NC} ${SERVER_IPS[$i]}"
done
echo

# Process each server
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  
  echo -e "${MAGENTA}=== Processing $SERVER_NAME server ($SERVER_IP) ===${NC}"
  
  if resize_instance "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully processed $SERVER_NAME server resize request.${NC}"
  else
    echo -e "${RED}✗ Failed to resize $SERVER_NAME server.${NC}"
  fi
  
  echo -e "${GREEN}=== Completed processing $SERVER_NAME server ===${NC}"
  echo
done

echo -e "${MAGENTA}=== Resize Summary ===${NC}"
echo -e "${YELLOW}Important Notes:${NC}"
echo -e "${BLUE}- The resize operations have been initiated but may take time to complete${NC}"
echo -e "${BLUE}- Servers may reboot during the resize process${NC}"
echo -e "${BLUE}- After resize completion, run the Hyperglass deployment script${NC}"
echo -e "${BLUE}- You can check resize status with:${NC}"
echo -e "${CYAN}  curl -H \"Authorization: Bearer $VULTR_API_KEY\" \"https://api.vultr.com/v2/instances\" | jq -r '.instances[] | \"\\(.main_ip) \\(.plan) \\(.status)\"'${NC}"
echo
echo -e "${GREEN}Resize operations initiated!${NC}"