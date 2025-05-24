#!/bin/bash
# Script to resize only the BGP speakers to 2GB RAM
# This script will identify and resize only the 4 BGP instances (LAX, EWR, MIA, ORD)

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
VULTR_API_KEY="OOBGITQGHOKATE5WMUYXCKE3UTA5O6OW4ENQ"

# Get server information from config file
LAX_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-west".lax.ipv4.address' "$CONFIG_FILE")
EWR_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".ewr.ipv4.address' "$CONFIG_FILE")
MIA_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".mia.ipv4.address' "$CONFIG_FILE")
ORD_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-central".ord.ipv4.address' "$CONFIG_FILE")

# Server list for iteration - ONLY BGP speakers
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

# Function to check instance plan and resize if needed
check_and_resize_instance() {
  local server_ip=$1
  local server_name=$2
  
  echo -e "${BLUE}Processing $server_name server ($server_ip)...${NC}"
  
  # Get the instance details
  local instance_info=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/instances" | \
    jq -r ".instances[] | select(.main_ip==\"$server_ip\")")
  
  if [ -z "$instance_info" ]; then
    echo -e "${RED}Failed to find instance for $server_name ($server_ip).${NC}"
    return 1
  fi
  
  # Extract the instance ID and current plan
  local instance_id=$(echo "$instance_info" | jq -r ".id")
  local current_plan=$(echo "$instance_info" | jq -r ".plan")
  local server_status=$(echo "$instance_info" | jq -r ".server_status")
  local power_status=$(echo "$instance_info" | jq -r ".power_status")
  
  echo -e "${GREEN}Found instance ID: $instance_id${NC}"
  echo -e "${BLUE}Current plan: $current_plan${NC}"
  echo -e "${BLUE}Server status: $server_status${NC}"
  echo -e "${BLUE}Power status: $power_status${NC}"
  
  # Check if already 2GB or higher
  if [[ "$current_plan" == *"2gb"* || "$current_plan" == *"4gb"* || "$current_plan" == *"8gb"* ]]; then
    echo -e "${GREEN}Server $server_name is already on a 2GB or higher plan ($current_plan). No resize needed.${NC}"
    return 0
  fi
  
  # Check if the server is locked
  if [ "$server_status" == "locked" ]; then
    echo -e "${YELLOW}Server $server_name is currently locked. Resize may be in progress.${NC}"
    return 0
  fi
  
  # 2GB RAM plan on Vultr is vc2-2c-2gb
  echo -e "${BLUE}Upgrading instance to 2GB plan...${NC}"
  local upgrade_response=$(curl -s -X PATCH \
    -H "Authorization: Bearer $VULTR_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"plan":"vc2-2c-2gb"}' \
    "https://api.vultr.com/v2/instances/$instance_id")
  
  # Check for errors in the response
  if echo "$upgrade_response" | jq -e '.error' > /dev/null; then
    echo -e "${RED}Failed to resize $server_name server.${NC}"
    echo -e "${RED}API Response: $upgrade_response${NC}"
    return 1
  else
    echo -e "${GREEN}Successfully initiated resize for $server_name server.${NC}"
    echo -e "${YELLOW}The server may reboot during this process.${NC}"
    return 0
  fi
}

# Main execution flow
echo -e "${MAGENTA}=== BGP Speaker Resize to 2GB RAM ===${NC}"
echo -e "${BLUE}This script will resize ONLY the BGP speakers to 2GB RAM.${NC}"
echo -e "${BLUE}BGP speakers to check and resize if needed:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  echo -e "  ${CYAN}${SERVER_NAMES[$i]}:${NC} ${SERVER_IPS[$i]}"
done
echo

# Get current status of all BGP speakers
echo -e "${BLUE}Current status of BGP speaker instances:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  
  instance_info=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/instances" | \
    jq -r ".instances[] | select(.main_ip==\"$SERVER_IP\")")
  
  if [ -n "$instance_info" ]; then
    plan=$(echo "$instance_info" | jq -r ".plan")
    status=$(echo "$instance_info" | jq -r ".status")
    server_status=$(echo "$instance_info" | jq -r ".server_status")
    
    echo -e "${CYAN}$SERVER_NAME (${SERVER_IP}):${NC} Plan: $plan, Status: $status, Server status: $server_status"
  else
    echo -e "${CYAN}$SERVER_NAME (${SERVER_IP}):${NC} ${RED}Not found${NC}"
  fi
done
echo

# Process each server
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  
  echo -e "${MAGENTA}=== Processing $SERVER_NAME server ($SERVER_IP) ===${NC}"
  
  if check_and_resize_instance "$SERVER_IP" "$SERVER_NAME"; then
    echo -e "${GREEN}✓ Successfully processed $SERVER_NAME server.${NC}"
  else
    echo -e "${RED}✗ Failed to process $SERVER_NAME server.${NC}"
  fi
  
  echo -e "${GREEN}=== Completed processing $SERVER_NAME server ===${NC}"
  echo
done

# Final status check
echo -e "${MAGENTA}=== Final Status Check ===${NC}"
echo -e "${BLUE}Current status of BGP speaker instances:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  
  instance_info=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/instances" | \
    jq -r ".instances[] | select(.main_ip==\"$SERVER_IP\")")
  
  if [ -n "$instance_info" ]; then
    plan=$(echo "$instance_info" | jq -r ".plan")
    status=$(echo "$instance_info" | jq -r ".status")
    server_status=$(echo "$instance_info" | jq -r ".server_status")
    
    echo -e "${CYAN}$SERVER_NAME (${SERVER_IP}):${NC} Plan: $plan, Status: $status, Server status: $server_status"
  else
    echo -e "${CYAN}$SERVER_NAME (${SERVER_IP}):${NC} ${RED}Not found${NC}"
  fi
done

echo -e "${MAGENTA}=== Resize Summary ===${NC}"
echo -e "${YELLOW}Important Notes:${NC}"
echo -e "${BLUE}- Resize operations for BGP speakers have been processed${NC}"
echo -e "${BLUE}- Servers may still be locked if resize is in progress${NC}"
echo -e "${BLUE}- After all servers are resized, run the Hyperglass deployment script${NC}"
echo -e "${BLUE}- You can monitor resize progress with:${NC}"
echo -e "${CYAN}  /home/normtodd/birdbgp/resize_bgp_speakers.sh${NC}"
echo
echo -e "${GREEN}BGP speaker resize operations complete!${NC}"