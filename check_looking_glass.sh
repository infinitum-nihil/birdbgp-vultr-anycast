#!/bin/bash
# check_looking_glass.sh - Diagnose looking glass issues

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to check server status
check_server() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Checking $server ($ip)...${NC}"
  
  # Check if server is reachable
  if ping -c 1 -W 3 $ip > /dev/null 2>&1; then
    echo -e "${GREEN}$server is reachable${NC}"
    
    # Check if SSH is available
    if ssh -o ConnectTimeout=5 -i "$SSH_KEY_PATH" "root@$ip" "echo Server is accessible" > /dev/null 2>&1; then
      echo -e "${GREEN}SSH to $server is working${NC}"
      
      # Check BIRD status
      echo -e "${BLUE}Checking BIRD status on $server...${NC}"
      ssh -o ConnectTimeout=5 -i "$SSH_KEY_PATH" "root@$ip" "
        if systemctl is-active bird &> /dev/null; then
          echo -e '${GREEN}BIRD is running${NC}'
          echo 'Router ID:'
          birdc show status | grep 'Router ID'
          echo 'BGP sessions:'
          birdc show protocols | grep -E 'BGP|ibgp|vultr'
          echo 'Routes for anycast block:'
          birdc show route for 192.30.120.0/23
        else
          echo -e '${RED}BIRD is not running${NC}'
          echo 'BIRD status:'
          systemctl status bird
        fi
      "
      
      # Check looking glass service if this is LAX
      if [ "$server" = "lax" ]; then
        echo -e "${BLUE}Checking looking glass services on LAX...${NC}"
        ssh -o ConnectTimeout=10 -i "$SSH_KEY_PATH" "root@$ip" "
          echo 'Hyperglass status:'
          systemctl status hyperglass
          
          echo 'Redis status:'
          systemctl status redis-server
          
          echo 'Nginx status:'
          systemctl status nginx
          
          echo 'Loopback interfaces:'
          ip addr show lo | grep -E '192.30.120.10|2620:71:4000'
          
          echo 'Nginx configuration:'
          ls -la /etc/nginx/sites-enabled/
          
          echo 'Checking hyperglass directory:'
          ls -la /opt/hyperglass/
          
          echo 'Checking hyperglass logs:'
          ls -la /var/log/hyperglass/
          cat /var/log/hyperglass/hyperglass.log | tail -20 || echo 'No hyperglass log found'
        "
      fi
    else
      echo -e "${RED}SSH to $server is not working${NC}"
    fi
  else
    echo -e "${RED}$server is not reachable${NC}"
  fi
  
  echo ""
}

# Main function
main() {
  echo -e "${BLUE}Starting looking glass diagnostics...${NC}"
  
  # Check DNS for looking glass domain
  echo -e "${BLUE}Checking DNS for looking glass...${NC}"
  host lg.infinitum-nihil.com || echo -e "${RED}Domain lookup failed${NC}"
  
  # Check if looking glass IP responds
  echo -e "${BLUE}Checking if looking glass anycast IP responds...${NC}"
  ping -c 2 -W 3 192.30.120.10 || echo -e "${RED}Anycast IP is not responding${NC}"
  
  # Check each server
  for server in "${!SERVER_IPS[@]}"; do
    check_server "$server"
  done
  
  echo -e "${BLUE}Diagnostics completed${NC}"
  echo -e "${YELLOW}Recommendations:${NC}"
  echo -e "1. Check if servers are running in Vultr control panel"
  echo -e "2. Verify BGP sessions are established with Vultr"
  echo -e "3. Ensure the anycast IP (192.30.120.10) is being announced properly"
  echo -e "4. Check hyperglass configuration on LAX server"
  echo -e "5. Verify nginx is properly configured to serve hyperglass"
}

# Run the main function
main