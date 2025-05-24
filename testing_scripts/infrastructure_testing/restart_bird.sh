#!/bin/bash
# restart_bird.sh - Restart BIRD on all servers

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
  ["ord"]="66.42.113.101"
  ["mia"]="149.28.108.180"
  ["ewr"]="66.135.18.138"
)

echo -e "${BLUE}Restarting BIRD on all servers...${NC}"

for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Restarting BIRD on $server ($ip)...${NC}"
  
  # Use a shorter timeout to avoid hanging
  ssh -o ConnectTimeout=10 -i "$SSH_KEY_PATH" "root@$ip" "
    # Stop BIRD
    systemctl stop bird || true
    
    # Ensure the run directory exists
    mkdir -p /run/bird
    chown bird:bird /run/bird
    
    # Start BIRD
    systemctl start bird
    
    # Check status
    systemctl status bird | grep Active
    
    # Check protocols
    birdc show protocols | grep -E 'ibgp|vultr' || echo 'No BGP protocols found'
  " || {
    echo -e "${RED}Failed to connect to $server ($ip).${NC}"
  }
done

echo -e "${GREEN}BIRD restart completed on all available servers.${NC}"