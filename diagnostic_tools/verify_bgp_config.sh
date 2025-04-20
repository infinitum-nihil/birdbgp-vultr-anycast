#!/bin/bash
# Script to verify BGP configuration on all servers
# Ensures proper Vultr BGP neighbor IPs and multihop settings

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

echo -e "${BOLD}========== BGP SERVERS VERIFICATION ==========${RESET}"
echo -e "${GREEN}Primary (EWR):${RESET} $EWR_IP"
echo -e "${GREEN}Secondary (MIA):${RESET} $MIA_IP"
echo -e "${GREEN}Tertiary (ORD):${RESET} $ORD_IP" 
echo -e "${GREEN}IPv6 (LAX):${RESET} $LAX_IP"
echo -e "${BOLD}=============================================${RESET}"

# Function to verify and fix BGP config on a server
verify_bgp_config() {
  local server_ip=$1
  local server_name=$2
  local is_ipv6=$3
  
  echo
  echo -e "${BOLD}Verifying BGP config on $server_name ($server_ip)...${RESET}"
  echo -e "${BOLD}-----------------------------------------------${RESET}"
  
  # Check if BIRD is running
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "systemctl status bird | grep Active" || {
    echo -e "${RED}❌ ERROR: Could not connect to $server_name ($server_ip) or BIRD service not running${RESET}"
    return 1
  }

  # Check current BGP neighbor configuration
  if [ "$is_ipv6" = "true" ]; then
    echo
    echo -e "${BOLD}Checking IPv6 BGP configuration:${RESET}"
    
    # Check IPv6 BGP neighbor configuration
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -B5 -A5 'neighbor 2001:19f0:ffff::1' /etc/bird/bird.conf || echo 'IPv6 BGP neighbor not correctly configured'"
    
    # Check if multihop is set to 2
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -B5 -A5 'multihop 2' /etc/bird/bird.conf" || {
      echo -e "${YELLOW}⚠️ WARNING: multihop 2 not configured correctly${RESET}"
      
      # Fix multihop setting if not set correctly
      echo -e "${BLUE}Fixing multihop setting...${RESET}"
      ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
        if grep -q 'multihop' /etc/bird/bird.conf; then
          # Replace existing multihop with correct setting
          sed -i 's/multihop [0-9];/multihop 2;/' /etc/bird/bird.conf
        else
          # Add multihop 2 before the neighbor line
          sed -i '/neighbor 2001:19f0:ffff::1/i\\    multihop 2;' /etc/bird/bird.conf
        fi
        
        # Verify the change
        grep -B5 -A5 'neighbor 2001:19f0:ffff::1' /etc/bird/bird.conf
      "
    }
    
    # Check for static route to Vultr's BGP server
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -A5 '2001:19f0:ffff::1' /etc/bird/bird.conf" || {
      echo -e "${YELLOW}⚠️ WARNING: Static route to Vultr's IPv6 BGP server not configured${RESET}"
      
      # Find the main interface
      MAIN_IF=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip -br link | grep -v 'lo' | head -1 | awk '{print \$1}'")
      
      # Fix static route if not set correctly
      echo -e "${BLUE}Adding static route using interface $MAIN_IF...${RESET}"
      ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
        # Add static route protocol if it doesn't exist
        if ! grep -q '2001:19f0:ffff::1' /etc/bird/bird.conf; then
          # Add static route definition
          cat >> /etc/bird/bird.conf << EOF
          
# Required static route to Vultr's BGP server
protocol static {
    ipv6;
    route 2001:19f0:ffff::1/128 via \"$MAIN_IF\";
}
EOF
        fi
        
        # Verify the change
        grep -A5 '2001:19f0:ffff::1' /etc/bird/bird.conf
      "
    }
  else
    echo
    echo -e "${BOLD}Checking IPv4 BGP configuration:${RESET}"
    
    # Check IPv4 BGP neighbor configuration
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -B5 -A5 'neighbor 169.254.169.254' /etc/bird/bird.conf || echo 'IPv4 BGP neighbor not correctly configured'"
    
    # Check if the BGP neighbor is correctly configured
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -q 'neighbor 169.254.169.254' /etc/bird/bird.conf" || {
      echo -e "${RED}❌ ERROR: IPv4 BGP neighbor not correctly configured${RESET}"
      
      # Fix BGP neighbor if not set correctly
      echo -e "${BLUE}Fixing BGP neighbor configuration...${RESET}"
      ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
        # Look for any existing neighbor configuration
        if grep -q 'neighbor.*as 64515' /etc/bird/bird.conf; then
          # Replace existing neighbor with correct neighbor
          sed -i 's/neighbor .* as 64515;/neighbor 169.254.169.254 as 64515;/' /etc/bird/bird.conf
        fi
        
        # Verify the change
        grep -B5 -A5 'as 64515' /etc/bird/bird.conf
      "
    }
    
    # Check if multihop is set to 2
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "grep -B5 -A5 'multihop 2' /etc/bird/bird.conf" || {
      echo -e "${YELLOW}⚠️ WARNING: multihop 2 not configured correctly${RESET}"
      
      # Fix multihop setting if not set correctly
      echo -e "${BLUE}Fixing multihop setting...${RESET}"
      ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
        if grep -q 'multihop' /etc/bird/bird.conf; then
          # Replace existing multihop with correct setting
          sed -i 's/multihop [0-9];/multihop 2;/' /etc/bird/bird.conf
        else
          # Add multihop 2 before the neighbor line
          sed -i '/neighbor 169.254.169.254/i\\    multihop 2;' /etc/bird/bird.conf
        fi
        
        # Verify the change
        grep -B5 -A5 'neighbor 169.254.169.254' /etc/bird/bird.conf
      "
    }
  fi
  
  # Restart BIRD after configuration changes
  echo
  echo -e "${BOLD}Restarting BIRD service...${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
    # Clean up any previous state
    systemctl stop bird
    killall -9 bird || true
    rm -rf /run/bird
    mkdir -p /run/bird
    chown bird:bird /run/bird
    
    # Test the config
    bird -p
    
    # Start BIRD
    systemctl start bird
    sleep 5
    
    # Check status
    systemctl status bird | grep Active
  "
  
  # Check BGP protocol status
  echo
  echo -e "${BOLD}Checking BGP protocol status:${RESET}"
  if [ "$is_ipv6" = "true" ]; then
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols all vultr6"
  else
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols all vultr"
  fi
  
  echo
  echo -e "${GREEN}✅ BGP configuration verified on $server_name ($server_ip)${RESET}"
  return 0
}

# Verify and fix each server
verify_bgp_config "$EWR_IP" "Primary (EWR)" "false"
verify_bgp_config "$MIA_IP" "Secondary (MIA)" "false"
verify_bgp_config "$ORD_IP" "Tertiary (ORD)" "false"
verify_bgp_config "$LAX_IP" "IPv6 (LAX)" "true"

echo
echo -e "${GREEN}BGP configuration verification completed for all servers${RESET}"
echo
echo "Run ./check_bgp_status.sh to get a full BGP status report"