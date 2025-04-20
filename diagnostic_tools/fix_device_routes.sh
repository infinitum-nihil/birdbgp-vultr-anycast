#!/bin/bash
# Script to ensure proper device routes for anycast IPs
# Convert blackhole routes to device routes

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# Text formatting for better readability
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"

echo -e "${BLUE}Getting BGP instance information...${RESET}"

# Set the IPs directly based on the ID files we know exist
EWR_IP=$(cat "$(dirname "$0")/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
MIA_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
ORD_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Check if IPs were found
if [ -z "$EWR_IP" ] || [ -z "$MIA_IP" ] || [ -z "$ORD_IP" ] || [ -z "$LAX_IP" ]; then
  echo -e "${RED}Error: Could not find all required IPs in IP files.${RESET}"
  echo "Found: EWR=$EWR_IP, MIA=$MIA_IP, ORD=$ORD_IP, LAX=$LAX_IP"
  exit 1
fi

echo -e "${BOLD}========== FIXING DEVICE ROUTES ==========${RESET}"
echo -e "${GREEN}Primary (EWR):${RESET} $EWR_IP"
echo -e "${GREEN}Secondary (MIA):${RESET} $MIA_IP"
echo -e "${GREEN}Tertiary (ORD):${RESET} $ORD_IP" 
echo -e "${GREEN}IPv6 (LAX):${RESET} $LAX_IP"
echo -e "${BOLD}=========================================${RESET}"

# IPv4 anycast prefix to announce
IPV4_PREFIX="192.30.120.0/23"
IPV4_ANYCAST="192.30.120.10/32"

# IPv6 anycast prefix to announce
IPV6_PREFIX="2620:71:4000::/48"
IPV6_ANYCAST="2620:71:4000::c01e:780a/128"

# Function to convert blackhole routes to device routes
fix_device_routes() {
  local server_ip=$1
  local server_name=$2
  local is_ipv6=$3
  
  echo
  echo -e "${BOLD}Fixing device routes on $server_name ($server_ip)...${RESET}"
  echo -e "${BOLD}-----------------------------------------------${RESET}"
  
  # Check if we can connect to the server
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "echo 'Connection successful'" || {
    echo -e "${RED}❌ ERROR: Could not connect to $server_name ($server_ip)${RESET}"
    return 1
  }
  
  # Check current routes in BIRD config
  echo
  echo -e "${BOLD}Current route configuration:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -A10 'protocol static' /etc/bird/bird.conf"
  
  # Make backup of current config
  echo
  echo -e "${BLUE}Making backup of current configuration...${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "cp /etc/bird/bird.conf /etc/bird/bird.conf.bak.$(date +%Y%m%d%H%M%S)"
  
  if [ "$is_ipv6" = "true" ]; then
    echo
    echo -e "${BOLD}Fixing IPv6 routes:${RESET}"
    
    # Fix IPv6 routes
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
      # Check if dummy interface exists
      if ! ip link show dummy0 >/dev/null 2>&1; then
        echo 'Creating dummy0 interface...'
        modprobe dummy
        ip link add dummy0 type dummy
        ip link set dummy0 up
        echo 'dummy' >> /etc/modules || true
      fi
      
      # Add IPv6 anycast address to dummy0 if not already added
      if ! ip -6 addr show dev dummy0 | grep -q '${IPV6_ANYCAST%/*}'; then
        echo 'Adding IPv6 anycast address to dummy0...'
        ip -6 addr add ${IPV6_ANYCAST} dev dummy0
      fi
      
      # Update BIRD config to use device routes instead of blackhole
      if grep -q 'route ${IPV6_PREFIX} blackhole' /etc/bird/bird.conf; then
        echo 'Converting IPv6 prefix from blackhole to device route...'
        sed -i 's|route ${IPV6_PREFIX} blackhole;|route ${IPV6_PREFIX} via \"dummy0\";|' /etc/bird/bird.conf
      fi
      
      # Add specific anycast route if not present
      if ! grep -q '${IPV6_ANYCAST%/*}' /etc/bird/bird.conf; then
        echo 'Adding specific IPv6 anycast route...'
        sed -i '/route ${IPV6_PREFIX}/a\\    route ${IPV6_ANYCAST} via \"dummy0\";' /etc/bird/bird.conf
      fi
    "
  else
    echo
    echo -e "${BOLD}Fixing IPv4 routes:${RESET}"
    
    # Fix IPv4 routes
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
      # Check if dummy interface exists
      if ! ip link show dummy0 >/dev/null 2>&1; then
        echo 'Creating dummy0 interface...'
        modprobe dummy
        ip link add dummy0 type dummy
        ip link set dummy0 up
        echo 'dummy' >> /etc/modules || true
      fi
      
      # Add IPv4 anycast address to dummy0 if not already added
      if ! ip addr show dev dummy0 | grep -q '${IPV4_ANYCAST%/*}'; then
        echo 'Adding IPv4 anycast address to dummy0...'
        ip addr add ${IPV4_ANYCAST} dev dummy0
      fi
      
      # Update BIRD config to use device routes instead of blackhole
      if grep -q 'route ${IPV4_PREFIX} blackhole' /etc/bird/bird.conf; then
        echo 'Converting IPv4 prefix from blackhole to device route...'
        sed -i 's|route ${IPV4_PREFIX} blackhole;|route ${IPV4_PREFIX} via \"dummy0\";|' /etc/bird/bird.conf
      fi
      
      # Add specific anycast route if not present
      if ! grep -q '${IPV4_ANYCAST%/*}' /etc/bird/bird.conf; then
        echo 'Adding specific IPv4 anycast route...'
        sed -i '/route ${IPV4_PREFIX}/a\\    route ${IPV4_ANYCAST} via \"dummy0\";' /etc/bird/bird.conf
      fi
    "
  fi
  
  # Check updated routes in BIRD config
  echo
  echo -e "${BOLD}Updated route configuration:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -A10 'protocol static' /etc/bird/bird.conf"
  
  # Restart BIRD to apply changes
  echo
  echo -e "${BOLD}Restarting BIRD service...${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
    systemctl restart bird
    sleep 5
    systemctl status bird | grep Active
  "
  
  echo
  echo -e "${GREEN}✅ Device routes fixed on $server_name ($server_ip)${RESET}"
  return 0
}

# Fix device routes on each server
fix_device_routes "$EWR_IP" "Primary (EWR)" "false"
fix_device_routes "$MIA_IP" "Secondary (MIA)" "false"
fix_device_routes "$ORD_IP" "Tertiary (ORD)" "false"
fix_device_routes "$LAX_IP" "IPv6 (LAX)" "true"

echo
echo -e "${GREEN}Device routes fixed on all servers${RESET}"
echo
echo "Run ./check_bgp_status.sh to verify BGP status"