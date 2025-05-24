#!/bin/bash
# upgrade_bird_2.17.1.sh - Upgrade all BGP servers to BIRD 2.17.1

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_nt_infinitum-nihil_com"

# Server details - LAX already has 2.17.1
declare -A SERVER_IPS=(
  ["ord"]="66.42.113.101"
  ["mia"]="149.28.108.180"
  ["ewr"]="66.135.18.138"
)

# Function to upgrade a server to BIRD 2.17.1
upgrade_server() {
  local server=$1
  local server_ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Upgrading BIRD on $server ($server_ip) to 2.17.1...${NC}"
  
  # Execute upgrade commands on the server
  ssh -i "$SSH_KEY_PATH" "root@$server_ip" "
    echo 'Stopping BIRD service...'
    systemctl stop bird
    
    echo 'Installing build dependencies...'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential flex bison autoconf libncurses-dev libreadline-dev git wget libssh-gcrypt-dev
    
    echo 'Backing up existing BIRD configuration...'
    mkdir -p /etc/bird/backup
    cp -r /etc/bird/* /etc/bird/backup/
    
    echo 'Downloading BIRD 2.17.1...'
    cd /tmp
    rm -rf bird-2.17.1 bird-2.17.1.tar.gz
    wget https://bird.network.cz/download/bird-2.17.1.tar.gz
    tar xzf bird-2.17.1.tar.gz
    cd bird-2.17.1
    
    echo 'Building BIRD 2.17.1...'
    autoreconf
    ./configure --prefix=/usr --sysconfdir=/etc/bird
    make
    
    echo 'Installing BIRD 2.17.1...'
    make install
    
    echo 'Verifying BIRD version...'
    bird --version
  "
  
  echo -e "${GREEN}BIRD 2.17.1 installed on $server.${NC}"
}

# Main execution
echo -e "${BLUE}Starting BIRD 2.17.1 upgrade on all servers...${NC}"
echo

for server in "${!SERVER_IPS[@]}"; do
  upgrade_server "$server"
  echo
done

echo -e "${GREEN}BIRD 2.17.1 upgrade completed on all servers.${NC}"
echo -e "${YELLOW}Now update the configuration files to be compatible with BIRD 2.17.1.${NC}"