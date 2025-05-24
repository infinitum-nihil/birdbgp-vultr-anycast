#!/bin/bash
# update_bird_version.sh - Upgrade all servers to BIRD 2.17.1

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_nt_infinitum-nihil_com"

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# Function to upgrade BIRD
upgrade_bird() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Upgrading BIRD on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Check current BIRD version
    current_version=\$(bird --version | awk '{print \$3}')
    echo \"Current BIRD version: \$current_version\"
    
    # If already at target version, skip
    if [ \"\$current_version\" = \"2.17.1\" ]; then
      echo \"Already at target version 2.17.1. Skipping.\"
      exit 0
    fi
    
    # Install dependencies
    apt-get update
    apt-get install -y flex bison libncurses-dev libreadline-dev build-essential autoconf libssh-gcrypt-dev
    
    # Backup current config
    echo \"Backing up current configuration...\"
    mkdir -p /etc/bird/backup
    cp -r /etc/bird/* /etc/bird/backup/
    
    # Download and build BIRD 2.17.1
    echo \"Downloading BIRD 2.17.1...\"
    cd /tmp
    wget https://bird.network.cz/download/bird-2.17.1.tar.gz
    tar -xzf bird-2.17.1.tar.gz
    cd bird-2.17.1
    
    # Configure and build
    echo \"Building BIRD 2.17.1...\"
    autoreconf
    ./configure --prefix=/usr --sysconfdir=/etc/bird
    make
    
    # Stop BIRD
    echo \"Stopping BIRD service...\"
    systemctl stop bird
    
    # Install
    echo \"Installing BIRD 2.17.1...\"
    make install
    
    # Restart BIRD
    echo \"Starting BIRD service...\"
    systemctl start bird
    
    # Verify new version
    echo \"Verifying BIRD version...\"
    bird --version
    
    # Show BIRD status
    echo \"BIRD service status:\"
    systemctl status bird | grep Active
  "
  
  echo -e "${GREEN}BIRD upgrade completed on $server.${NC}"
  echo
}

# Main function
main() {
  echo -e "${BLUE}Upgrading BIRD to version 2.17.1 on all servers...${NC}"
  echo
  
  for server in "${!SERVER_IPS[@]}"; do
    if [ "$server" != "lax" ]; then  # Skip LAX as it's already at 2.17.1
      upgrade_bird "$server"
    else
      echo -e "${YELLOW}Skipping LAX as it's already at version 2.17.1${NC}"
      echo
    fi
  done
  
  echo -e "${GREEN}BIRD upgrade completed on all servers.${NC}"
  echo -e "${YELLOW}Now checking BGP sessions status...${NC}"
  echo
  
  # Run the check script to verify BGP status
  bash /home/normtodd/birdbgp/check_bgp_sessions.sh
}

# Run the main function
main