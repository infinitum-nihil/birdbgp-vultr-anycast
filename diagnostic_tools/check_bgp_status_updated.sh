#!/bin/bash
# Script to check BGP status on all instances with BIRD 2.16.2

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

echo "Getting BGP instance information..."

# Get region information from .env file
if [ -z "$BGP_REGION_PRIMARY" ] || [ -z "$BGP_REGION_SECONDARY" ] || [ -z "$BGP_REGION_TERTIARY" ] || [ -z "$BGP_REGION_QUATERNARY" ]; then
  echo "Error: One or more BGP regions are not defined in .env file"
  echo "Please ensure BGP_REGION_PRIMARY, BGP_REGION_SECONDARY, BGP_REGION_TERTIARY, and BGP_REGION_QUATERNARY are set"
  exit 1
fi

# Set the IPs based on the region information from .env
PRIMARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_PRIMARY}-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_PRIMARY}-dual-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
SECONDARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_SECONDARY}-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_SECONDARY}-dual-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
TERTIARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_TERTIARY}-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_TERTIARY}-dual-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
QUATERNARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_QUATERNARY}-ipv4-bgp-quaternary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_QUATERNARY}-dual-bgp-quaternary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_QUATERNARY}-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Check if IPs were found
if [ -z "$PRIMARY_IP" ] || [ -z "$SECONDARY_IP" ] || [ -z "$TERTIARY_IP" ] || [ -z "$QUATERNARY_IP" ]; then
  echo "Error: Could not find all required IPs in IP files."
  echo "Found: PRIMARY(${BGP_REGION_PRIMARY})=$PRIMARY_IP, SECONDARY(${BGP_REGION_SECONDARY})=$SECONDARY_IP, TERTIARY(${BGP_REGION_TERTIARY})=$TERTIARY_IP, QUATERNARY(${BGP_REGION_QUATERNARY})=$QUATERNARY_IP"
  exit 1
fi

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"

echo -e "${BOLD}========== BGP SERVERS STATUS ==========${RESET}"
echo -e "${GREEN}Primary (${BGP_REGION_PRIMARY}, 0x prepend):${RESET} $PRIMARY_IP"
echo -e "${GREEN}Secondary (${BGP_REGION_SECONDARY}, 1x prepend):${RESET} $SECONDARY_IP"
echo -e "${GREEN}Tertiary (${BGP_REGION_TERTIARY}, 2x prepend):${RESET} $TERTIARY_IP" 
echo -e "${GREEN}Quaternary (${BGP_REGION_QUATERNARY}, 2x prepend):${RESET} $QUATERNARY_IP"
echo -e "${BOLD}========================================${RESET}"

# Function to check BIRD status on a server
check_bird_status() {
  local server_ip=$1
  local server_name=$2
  local region=$3
  local prepend=$4
  
  echo
  echo -e "${BOLD}Checking $server_name (${region}, ${prepend}x prepend) BGP status on $server_ip...${RESET}"
  echo -e "${BOLD}-----------------------------------------------${RESET}"
  
  # Check BIRD version and status
  echo -e "${BOLD}BIRD Version and Status:${RESET}"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "birdc show status | grep -E 'BIRD|up'" || {
    echo "❌ ERROR: Could not get BIRD status"
    return 1
  }
  
  # Get BGP protocol status - both IPv4 and IPv6
  echo
  echo -e "${BOLD}BGP Protocol Status:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols | grep -E 'vultr|Name'" || {
    echo "❌ ERROR: Could not get BGP protocol status"
    return 1
  }
  
  # Get IPv4 BGP details
  echo
  echo -e "${BOLD}IPv4 BGP Details:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols all vultr_v4 | head -20" || {
    echo "❌ ERROR: Could not get IPv4 BGP details"
  }
  
  # Get IPv6 BGP details (all servers now support IPv6)
  echo
  echo -e "${BOLD}IPv6 BGP Details:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols all vultr_v6 | head -20" || {
    echo "❌ ERROR: Could not get IPv6 BGP details"
  }

  # Check BGP route counts
  echo
  echo -e "${BOLD}BGP Routes:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show route count" || {
    echo "❌ ERROR: Could not get route counts"
    return 1
  }
  
  # Check network interfaces for IP addresses
  echo
  echo -e "${BOLD}Network Interfaces (check for IP addresses):${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip addr show | grep -E 'inet |inet6' | grep -v '127.0.0.1' | grep -v '::1'" || {
    echo "❌ ERROR: Could not check network interfaces"
    return 1
  }
  
  echo
  echo -e "${GREEN}✅ $server_name (${region}, ${prepend}x prepend) BGP status check completed${RESET}"
  return 0
}

# Check each server
check_bird_status "$PRIMARY_IP" "Primary" "${BGP_REGION_PRIMARY}" "0"
check_bird_status "$SECONDARY_IP" "Secondary" "${BGP_REGION_SECONDARY}" "1"  
check_bird_status "$TERTIARY_IP" "Tertiary" "${BGP_REGION_TERTIARY}" "2"
check_bird_status "$QUATERNARY_IP" "Quaternary" "${BGP_REGION_QUATERNARY}" "2"

echo
echo -e "${GREEN}BGP status check completed for all servers${RESET}"
echo
echo "To restart BGP on any server, use: ssh root@<server_ip> systemctl restart bird"
echo "To test failover, stop BGP on the primary: ssh root@$PRIMARY_IP systemctl stop bird"
