#!/bin/bash
# fix_bird_router_ids.sh - Sets explicit router IDs in BIRD configuration

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_nt_infinitum-nihil_com"  # Key for nt@infinitum-nihil.com

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# WireGuard IPs based on geographic proximity to LA headquarters
declare -A WG_IPS=(
  ["lax"]="10.10.10.1"  # Primary - Los Angeles (HQ)
  ["ord"]="10.10.10.2"  # Secondary - Chicago (closest to LA)
  ["mia"]="10.10.10.3"  # Tertiary - Miami (farther from LA)
  ["ewr"]="10.10.10.4"  # Quaternary - Newark (farthest from LA)
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to fix BIRD router ID
fix_router_id() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  # Use the public IP as router ID instead of WireGuard IP
  
  echo -e "${BLUE}Fixing BIRD router ID on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" root@$ip "
    # Set explicit router ID in BIRD configuration using the public IP
    PUBLIC_IP=$ip
    if grep -q 'router id from' /etc/bird/bird.conf; then
      sed -i \"s|router id from .*|router id \$PUBLIC_IP;|\" /etc/bird/bird.conf
    else
      sed -i \"s|^router id .*;|router id \$PUBLIC_IP;|\" /etc/bird/bird.conf
    fi
    
    # Make sure firewall allows BGP traffic
    iptables -A INPUT -p tcp --dport 179 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 179 -j ACCEPT
    
    # Allow all traffic on WireGuard interface
    iptables -A INPUT -i wg0 -j ACCEPT
    iptables -A OUTPUT -o wg0 -j ACCEPT
    iptables -A FORWARD -i wg0 -j ACCEPT
    iptables -A FORWARD -o wg0 -j ACCEPT
    
    # Restart BIRD
    systemctl restart bird
    
    # Check if BIRD is running
    if systemctl is-active bird &> /dev/null; then
      echo 'BIRD successfully restarted with new router ID'
    else
      echo 'BIRD failed to start after setting router ID:'
      systemctl status bird
    fi
  "
}

# Function to check BGP status
check_bgp_status() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Checking BGP status on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" root@$ip "
    # Check BGP protocol status
    echo 'BGP protocol status:'
    birdc show protocols | grep -A 1 BGP
    
    # Check BGP routes
    echo -e '\nBGP routes:'
    birdc show route where proto ~ \"bgp*\"
    
    # Check router ID
    echo -e '\nRouter ID:'
    birdc show status | grep 'Router ID'
  "
}

# Main function
main() {
  echo -e "${BLUE}Starting BIRD router ID fix...${NC}"
  
  # Check if a specific server was provided as argument
  if [ $# -eq 1 ]; then
    server=$1
    if [[ -n "${SERVER_IPS[$server]}" ]]; then
      # Fix router ID for the specified server
      fix_router_id "$server"
      
      # Wait for BGP sessions to establish
      echo -e "${YELLOW}Waiting 10 seconds for BGP sessions to establish...${NC}"
      sleep 10
      
      # Check BGP status for the specified server
      check_bgp_status "$server"
      
      echo -e "${GREEN}BIRD router ID fix completed for $server!${NC}"
    else
      echo -e "${RED}Unknown server: $server${NC}"
      echo -e "Available servers: ${!SERVER_IPS[*]}"
    fi
  else
    # Fix router IDs on all servers
    for server in "${!SERVER_IPS[@]}"; do
      fix_router_id "$server"
    done
    
    # Wait for BGP sessions to establish
    echo -e "${YELLOW}Waiting 20 seconds for BGP sessions to establish...${NC}"
    sleep 20
    
    # Check BGP status on all servers
    for server in "${!SERVER_IPS[@]}"; do
      check_bgp_status "$server"
    done
    
    echo -e "${GREEN}BIRD router ID fix completed!${NC}"
  fi
}

# Run the main function with command-line arguments
main "$@"