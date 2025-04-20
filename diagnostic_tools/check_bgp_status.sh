#!/bin/bash
# Script to check BGP status on all instances
# Updated to use region-agnostic naming and role-based structure

# Source .env file to get SSH key path and region configuration
source "$(dirname "$0")/.env"

# Text formatting for better readability
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"

echo -e "${BLUE}Getting BGP instance information...${RESET}"

# Get region information from .env file
if [ -z "$BGP_REGION_PRIMARY" ] || [ -z "$BGP_REGION_SECONDARY" ] || [ -z "$BGP_REGION_TERTIARY" ]; then
  echo -e "${RED}Error: BGP region variables not set in .env file.${RESET}"
  echo "Ensure BGP_REGION_PRIMARY, BGP_REGION_SECONDARY, and BGP_REGION_TERTIARY are set."
  
  # Check for older hardcoded file structure
  if [ -f "$(dirname "$0")/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" ]; then
    echo -e "${YELLOW}Found older hardcoded files. Run ./reassign_bgp_roles.sh to update your configuration.${RESET}"
  fi
  
  exit 1
fi

# Set quaternary region if not defined
BGP_REGION_QUATERNARY=${BGP_REGION_QUATERNARY:-$BGP_REGION_TERTIARY}

# Lookup IPs based on roles, not region names
# This is necessary for compatibility with the original file naming

# For compatibility with original deployment
if [ "$BGP_REGION_PRIMARY" = "lax" ]; then
  PRIMARY_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_PRIMARY" = "ewr" ]; then
  PRIMARY_IP=$(cat "$(dirname "$0")/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_PRIMARY" = "mia" ]; then
  PRIMARY_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_PRIMARY" = "ord" ]; then
  PRIMARY_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
fi

if [ "$BGP_REGION_SECONDARY" = "lax" ]; then
  SECONDARY_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_SECONDARY" = "ewr" ]; then
  SECONDARY_IP=$(cat "$(dirname "$0")/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_SECONDARY" = "mia" ]; then
  SECONDARY_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_SECONDARY" = "ord" ]; then
  SECONDARY_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
fi

if [ "$BGP_REGION_TERTIARY" = "lax" ]; then
  TERTIARY_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_TERTIARY" = "ewr" ]; then
  TERTIARY_IP=$(cat "$(dirname "$0")/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_TERTIARY" = "mia" ]; then
  TERTIARY_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_TERTIARY" = "ord" ]; then
  TERTIARY_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
fi

if [ "$BGP_REGION_QUATERNARY" = "lax" ]; then
  QUATERNARY_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_QUATERNARY" = "ewr" ]; then
  QUATERNARY_IP=$(cat "$(dirname "$0")/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_QUATERNARY" = "mia" ]; then
  QUATERNARY_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
elif [ "$BGP_REGION_QUATERNARY" = "ord" ]; then
  QUATERNARY_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
fi

# Check if IPs were found
if [ -z "$PRIMARY_IP" ] || [ -z "$SECONDARY_IP" ] || [ -z "$TERTIARY_IP" ] || [ -z "$QUATERNARY_IP" ]; then
  echo -e "${RED}Error: Could not find all required IPs in IP files.${RESET}"
  echo -e "Found: PRIMARY(${BGP_REGION_PRIMARY})=${PRIMARY_IP:-Not found}, SECONDARY(${BGP_REGION_SECONDARY})=${SECONDARY_IP:-Not found}, TERTIARY(${BGP_REGION_TERTIARY})=${TERTIARY_IP:-Not found}, QUATERNARY(${BGP_REGION_QUATERNARY})=${QUATERNARY_IP:-Not found}"
  exit 1
fi

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
  
  # Check if BIRD service is running
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "systemctl status bird | grep Active" || {
    echo -e "${RED}❌ ERROR: Could not connect to $server_name ($server_ip) or BIRD service not running${RESET}"
    return 1
  }
  
  # Get BIRD protocol status - both IPv4 and IPv6
  echo
  echo -e "${BOLD}BGP Protocol Status:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols | grep -E 'vultr|Name'" || {
    echo -e "${RED}❌ ERROR: Could not get BGP protocol status${RESET}"
    return 1
  }
  
  # Get BGP route counts
  echo
  echo -e "${BOLD}BGP Routes:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show route count" || {
    echo -e "${RED}❌ ERROR: Could not get route counts${RESET}"
    return 1
  }
  
  # Get route details
  echo
  echo -e "${BOLD}Route Details:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show route | head -10" || {
    echo -e "${RED}❌ ERROR: Could not get route details${RESET}"
    return 1
  }
  
  # Check IP configuration
  echo
  echo -e "${BOLD}Network Interfaces:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip addr | grep -E 'inet |inet6' | grep -v '127.0.0.1' | grep -v '::1'" || {
    echo -e "${RED}❌ ERROR: Could not check network interfaces${RESET}"
    return 1
  }
  
  # Check path prepending configuration
  echo
  echo -e "${BOLD}Path Prepending Configuration:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -A 5 'bgp_path.prepend' /etc/bird/bird.conf || echo 'No path prepending (primary server)'" || {
    echo -e "${RED}❌ ERROR: Could not check path prepending configuration${RESET}"
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
echo 
echo -e "${BLUE}Tip: Use ./reassign_bgp_roles.sh to change server roles and update path prepending.${RESET}"