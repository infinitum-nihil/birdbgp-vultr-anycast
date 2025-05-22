#!/bin/bash
# check_mesh_connectivity.sh - Verifies WireGuard mesh network connectivity

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# WireGuard IPs
declare -A WG_IPS=(
  ["lax"]="10.10.10.1"
  ["ewr"]="10.10.10.2"
  ["mia"]="10.10.10.3"
  ["ord"]="10.10.10.4"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to check WireGuard status
check_wireguard() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Checking WireGuard status on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Check if WireGuard interface exists
    if ! ip link show wg0 &> /dev/null; then
      echo 'WireGuard interface (wg0) does not exist!'
      exit 1
    fi
    
    # Check if WireGuard interface is up
    if ! ip link show wg0 | grep -q 'UP'; then
      echo 'WireGuard interface (wg0) is not up!'
      exit 1
    fi
    
    # Show WireGuard status
    echo 'WireGuard status:'
    wg show
    
    # Show WireGuard IP address
    echo -e '\nWireGuard IP address:'
    ip addr show wg0
    
    # Show routing table for WireGuard subnet
    echo -e '\nRouting table for WireGuard subnet:'
    ip route | grep '10.10.10'
  "
}

# Function to check connectivity to other nodes
check_connectivity() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Checking connectivity from $server ($ip) to other nodes...${NC}"
  
  for target in "${!WG_IPS[@]}"; do
    if [ "$target" != "$server" ]; then
      local target_wg_ip=${WG_IPS[$target]}
      
      echo -e "${YELLOW}Checking connectivity to $target ($target_wg_ip)...${NC}"
      
      ssh -i "$SSH_KEY_PATH" "root@$ip" "
        # Ping the target
        echo 'Ping test:'
        ping -c 3 -W 2 $target_wg_ip || echo 'Ping failed!'
        
        # Traceroute to the target
        echo -e '\nTraceroute:'
        traceroute -m 5 $target_wg_ip || echo 'Traceroute failed!'
        
        # Check if we can connect to the BGP port
        echo -e '\nTCP connection test (port 179):'
        timeout 5 nc -zv $target_wg_ip 179 || echo 'TCP connection failed!'
      "
    fi
  done
}

# Function to fix WireGuard configuration if needed
fix_wireguard() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Fixing WireGuard configuration on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Restart WireGuard interface
    systemctl restart wg-quick@wg0
    
    # Check status
    systemctl status wg-quick@wg0 || true
    
    # Make sure BIRD has the correct router ID
    sed -i 's/router id from \"wg0\";/router id ${WG_IPS[$server]};/' /etc/bird/bird.conf
    
    # Restart BIRD
    systemctl restart bird
  "
}

# Main function
main() {
  echo -e "${BLUE}Checking WireGuard mesh network connectivity...${NC}"
  
  # Check WireGuard status on all servers
  for server in "${!SERVER_IPS[@]}"; do
    check_wireguard "$server" || {
      echo -e "${RED}WireGuard issue detected on $server. Fixing...${NC}"
      fix_wireguard "$server"
    }
  done
  
  # Check connectivity between servers
  for server in "${!SERVER_IPS[@]}"; do
    check_connectivity "$server"
  done
  
  echo -e "${GREEN}WireGuard mesh network connectivity check completed!${NC}"
}

# Run the main function
main