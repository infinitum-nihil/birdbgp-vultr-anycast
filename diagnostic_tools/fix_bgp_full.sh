#!/bin/bash
# Master script to fix and verify BGP configuration on all servers
# This script performs a comprehensive fix of BGP configuration:
# 1. Verifies correct BGP neighbor IPs (169.254.169.254 for IPv4, 2001:19f0:ffff::1 for IPv6)
# 2. Ensures multihop is set to 2
# 3. Converts blackhole routes to device routes
# 4. Ensures anycast IPs are properly announced

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# Text formatting for better readability
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"

echo -e "${BLUE}${BOLD}==============================================${RESET}"
echo -e "${BLUE}${BOLD}  COMPREHENSIVE BGP CONFIGURATION FIX SCRIPT  ${RESET}"
echo -e "${BLUE}${BOLD}==============================================${RESET}"
echo

# Check if scripts exist
if [ ! -f "$(dirname "$0")/verify_bgp_config.sh" ] || [ ! -f "$(dirname "$0")/fix_device_routes.sh" ]; then
  echo -e "${RED}Error: Required scripts not found.${RESET}"
  echo "Make sure the following scripts exist in the same directory:"
  echo "- verify_bgp_config.sh"
  echo "- fix_device_routes.sh"
  exit 1
fi

# Ask for confirmation
echo -e "${YELLOW}WARNING:${RESET} This script will modify BIRD configuration on all servers."
echo -e "It will ensure proper BGP configuration for Vultr, including:"
echo "  - Correct neighbor IPs (169.254.169.254 for IPv4, 2001:19f0:ffff::1 for IPv6)"
echo "  - Multihop 2 setting"
echo "  - Device routes instead of blackhole routes"
echo "  - Proper anycast IP configuration"
echo
read -p "Do you want to continue? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Operation cancelled."
  exit 0
fi

echo
echo -e "${BLUE}${BOLD}STEP 1: VERIFYING BGP NEIGHBOR CONFIGURATION${RESET}"
echo -e "${BLUE}${BOLD}---------------------------------------------${RESET}"
./verify_bgp_config.sh

echo
echo -e "${BLUE}${BOLD}STEP 2: FIXING DEVICE ROUTES FOR ANYCAST IPS${RESET}"
echo -e "${BLUE}${BOLD}---------------------------------------------${RESET}"
./fix_device_routes.sh

echo
echo -e "${BLUE}${BOLD}STEP 3: CHECKING FINAL BGP STATUS${RESET}"
echo -e "${BLUE}${BOLD}---------------------------------------------${RESET}"
./check_bgp_status.sh

echo
echo -e "${GREEN}${BOLD}==============================================${RESET}"
echo -e "${GREEN}${BOLD}  BGP CONFIGURATION FIX COMPLETED  ${RESET}"
echo -e "${GREEN}${BOLD}==============================================${RESET}"
echo
echo -e "To test anycast routing, ping or run nmap on:"
echo -e "  - IPv4: 192.30.120.10"
echo -e "  - IPv6: 2620:71:4000::c01e:780a"
echo
echo -e "If BGP is still not established, check:"
echo -e "  1. Firewall settings (TCP port 179 must be open for BGP)"
echo -e "  2. BGP password accuracy"
echo -e "  3. Vultr private AS number (should be 64515)"
echo -e "  4. BIRD version (2.0.8+ recommended)"