#!/bin/bash
# fix_wireguard_ip_assignment.sh - Script to restart the WireGuard mesh network with updated IP assignments

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# WireGuard IPs - based on geographic proximity to LA headquarters
declare -A WG_IPS=(
  ["lax"]="10.10.10.1"  # Primary - Los Angeles (HQ)
  ["ord"]="10.10.10.2"  # Secondary - Chicago (closest to LA)
  ["mia"]="10.10.10.3"  # Tertiary - Miami (farther from LA)
  ["ewr"]="10.10.10.4"  # Quaternary - Newark (farthest from LA)
)

# Clear and restart all servers
restart_bgp_mesh() {
  echo -e "${BLUE}Restarting BGP mesh network with corrected WireGuard IPs...${NC}"
  
  for server in "${!SERVER_IPS[@]}"; do
    local ip=${SERVER_IPS[$server]}
    local wg_ip=${WG_IPS[$server]}
    
    echo -e "${YELLOW}Restarting services on $server ($ip)...${NC}"
    
    ssh -i "$SSH_KEY_PATH" "root@$ip" "
      # Stop and restart WireGuard
      echo 'Stopping WireGuard...'
      systemctl stop wg-quick@wg0 || true
      
      # Ensure IP assignment is correct in config
      echo 'Checking WireGuard config...'
      if ! grep -q 'Address = $wg_ip' /etc/wireguard/wg0.conf; then
        echo 'Updating WireGuard IP address...'
        sed -i 's|Address = .*|Address = $wg_ip/24|' /etc/wireguard/wg0.conf
      fi
      
      # Start WireGuard
      echo 'Starting WireGuard...'
      systemctl start wg-quick@wg0
      
      # Check WireGuard status
      echo 'WireGuard status:'
      wg show
      
      # Restart BIRD
      echo 'Restarting BIRD...'
      systemctl restart bird
      
      # Check iBGP protocols
      echo 'Checking iBGP protocols:'
      sleep 5  # Wait for protocols to establish
      birdc show protocols | grep -i ibgp || echo 'No iBGP protocols found'
    " || {
      echo -e "${RED}Failed to restart services on $server ($ip)${NC}"
    }
  done
  
  echo -e "${GREEN}BGP mesh network has been restarted with corrected WireGuard IPs${NC}"
}

# Check connectivity between servers
check_connectivity() {
  echo -e "${BLUE}Checking connectivity between all servers...${NC}"
  
  for server in "${!SERVER_IPS[@]}"; do
    local ip=${SERVER_IPS[$server]}
    local wg_ip=${WG_IPS[$server]}
    
    echo -e "${YELLOW}Checking connectivity from $server ($ip)...${NC}"
    
    # Check connectivity to other servers
    for target in "${!SERVER_IPS[@]}"; do
      if [ "$server" != "$target" ]; then
        local target_wg_ip=${WG_IPS[$target]}
        
        echo -e "${BLUE}Testing connection to $target ($target_wg_ip)...${NC}"
        
        # Try to ping the target
        ssh -i "$SSH_KEY_PATH" "root@$ip" "
          echo 'Ping test:'
          ping -c 2 -W 2 $target_wg_ip || echo 'Ping failed!'
          
          echo 'BGP connection test:'
          timeout 5 nc -zv $target_wg_ip 179 || echo 'BGP port connection failed!'
        " || {
          echo -e "${RED}Failed to check connectivity from $server to $target${NC}"
        }
      fi
    done
  done
  
  echo -e "${GREEN}Connectivity check completed${NC}"
}

# Main function
main() {
  echo -e "${BLUE}Starting WireGuard IP assignment fix...${NC}"
  echo -e "${YELLOW}This script will restart the WireGuard mesh network with the following IP assignments:${NC}"
  echo -e "  LAX (primary): ${WG_IPS["lax"]}"
  echo -e "  ORD (secondary): ${WG_IPS["ord"]}"
  echo -e "  MIA (tertiary): ${WG_IPS["mia"]}"
  echo -e "  EWR (quaternary): ${WG_IPS["ewr"]}"
  echo
  
  # Restart BGP mesh
  restart_bgp_mesh
  
  # Check connectivity
  check_connectivity
  
  # Final instructions
  echo
  echo -e "${GREEN}WireGuard IP assignment fix complete!${NC}"
  echo -e "${YELLOW}To verify BGP session status, run:${NC} bash /home/normtodd/birdbgp/diagnostic_tools/check_bgp_status_updated.sh"
  echo
}

# Run the main function
main