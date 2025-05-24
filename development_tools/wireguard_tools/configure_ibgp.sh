#!/bin/bash
# configure_ibgp.sh - Sets up iBGP over WireGuard mesh network
# Creates iBGP sessions between all BGP speakers with LAX as route reflector

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed
INTERNAL_ASN=65001  # Private ASN for iBGP mesh
PUBLIC_ASN=27218    # Public ASN assigned by ARIN
PROVIDER_ASN=64515  # Vultr's ASN

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# Server roles
declare -A SERVER_ROLES=(
  ["lax"]="primary"    # Route reflector
  ["ewr"]="secondary"
  ["mia"]="tertiary"
  ["ord"]="quaternary"
)

# WireGuard IPs based on geographic proximity to LA headquarters
declare -A WG_IPS=(
  ["lax"]="10.10.10.1"  # Primary - Los Angeles (HQ)
  ["ord"]="10.10.10.2"  # Secondary - Chicago (closest to LA)
  ["mia"]="10.10.10.3"  # Tertiary - Miami (farther from LA)
  ["ewr"]="10.10.10.4"  # Quaternary - Newark (farthest from LA)
)

# Anycast network blocks
IPV4_BLOCKS=("192.30.120.0/23")
IPV6_BLOCKS=("2620:71:4000::/48")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file setup
LOG_FILE="ibgp_config_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to check and install BIRD2 if needed
ensure_bird() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Ensuring BIRD2 is installed on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Check if BIRD2 is installed
    if ! command -v birdc &> /dev/null; then
      echo 'BIRD2 not found, installing...'
      
      # Fix any interrupted package operations
      dpkg --configure -a
      
      # Update package lists
      DEBIAN_FRONTEND=noninteractive apt-get update
      
      # Install BIRD2
      DEBIAN_FRONTEND=noninteractive apt-get install -y bird2
      
      # Ensure BIRD service is enabled
      systemctl enable bird
    else
      echo 'BIRD2 is already installed'
    fi
    
    # Create a basic bird.conf if it doesn't exist
    if [ ! -f /etc/bird/bird.conf ]; then
      mkdir -p /etc/bird
      cat > /etc/bird/bird.conf << EOL
# Basic BIRD2 configuration
# Created by configure_ibgp.sh

log syslog all;
router id ${WG_IPS[$server]};

# Protocol definitions
protocol device {
  scan time 10;
}

protocol direct {
  ipv4;
  ipv6;
}

protocol kernel {
  ipv4 {
    export all;
  };
  learn;
}

protocol kernel {
  ipv6 {
    export all;
  };
  learn;
}

# Include other configuration files
EOL
    fi
    
    # Create config directories if they don't exist
    mkdir -p /etc/bird/conf.d
    
    # Restart BIRD to make sure it's running
    systemctl restart bird || {
      echo 'Failed to start BIRD, checking logs:'
      systemctl status bird || true
      journalctl -xe -u bird | tail -n 30 || true
    }
  "
  
  echo -e "${GREEN}BIRD2 installation checked on $server.${NC}"
}

# Function to create route reflector configuration
create_rr_config() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Creating route reflector configuration on $server ($ip)...${NC}"
  
  # Generate route reflector configuration
  local config="# iBGP Route Reflector Configuration
# Created by configure_ibgp.sh on $(date)
# Server: $server (${WG_IPS[$server]})

# Define route reflector cluster ID
define rr_cluster_id = 1;

# Template for iBGP clients
template bgp ibgp_clients {
  local as $INTERNAL_ASN;
  rr client;
  rr cluster id rr_cluster_id;
  hold time 30;
  multihop;
  ipv4 {
    import all;
    export all;
  };
  ipv6 {
    import all;
    export all;
  };
}

# iBGP client sessions
"
  
  # Add client configurations for each server
  for client in "${!SERVER_IPS[@]}"; do
    if [ "$client" != "$server" ]; then
      config+="protocol bgp ibgp_$client from ibgp_clients {
  neighbor ${WG_IPS[$client]} as $INTERNAL_ASN;
  description \"iBGP to $client (${SERVER_ROLES[$client]})\";
}

"
    fi
  done
  
  # Add static routes for anycast network blocks
  config+="# Static routes for anycast network blocks
protocol static static_anycast_v4 {
  ipv4 {
    export all;
  };
  
  # IPv4 anycast network blocks
"
  
  # Add IPv4 blocks
  for block in "${IPV4_BLOCKS[@]}"; do
    config+="  route $block blackhole;
"
  done
  
  config+="}

protocol static static_anycast_v6 {
  ipv6 {
    export all;
  };
  
  # IPv6 anycast network blocks
"
  
  # Add IPv6 blocks
  for block in "${IPV6_BLOCKS[@]}"; do
    config+="  route $block blackhole;
"
  done
  
  config+="}"
  
  # Upload configuration to server
  echo "$config" | ssh -i "$SSH_KEY_PATH" "root@$ip" "cat > /etc/bird/conf.d/ibgp_rr.conf"
  
  # Update main configuration to include the file
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Make sure the include statement is in bird.conf
    if ! grep -q 'include \"/etc/bird/conf.d/ibgp_.*\\.conf\";' /etc/bird/bird.conf; then
      echo 'include \"/etc/bird/conf.d/ibgp_*.conf\";' >> /etc/bird/bird.conf
    fi
    
    # Apply configuration
    birdc configure || {
      echo 'Failed to apply configuration, checking syntax:'
      birdc -c 'configure check' || true
    }
  "
  
  echo -e "${GREEN}Route reflector configuration created on $server.${NC}"
}

# Function to create client configuration
create_client_config() {
  local server=$1
  local rr_server=$2
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Creating iBGP client configuration on $server ($ip)...${NC}"
  
  # Generate client configuration
  local config="# iBGP Client Configuration
# Created by configure_ibgp.sh on $(date)
# Server: $server (${WG_IPS[$server]})
# Route Reflector: $rr_server (${WG_IPS[$rr_server]})

# iBGP session to route reflector
protocol bgp ibgp_$rr_server {
  local as $INTERNAL_ASN;
  neighbor ${WG_IPS[$rr_server]} as $INTERNAL_ASN;
  hold time 30;
  multihop;
  ipv4 {
    import all;
    export all;
  };
  ipv6 {
    import all;
    export all;
  };
  description \"iBGP to Route Reflector ($rr_server)\";
}

# Static routes for anycast network blocks
protocol static static_anycast_v4 {
  ipv4 {
    export all;
  };
  
  # IPv4 anycast network blocks
"
  
  # Add IPv4 blocks
  for block in "${IPV4_BLOCKS[@]}"; do
    config+="  route $block blackhole;
"
  done
  
  config+="}

protocol static static_anycast_v6 {
  ipv6 {
    export all;
  };
  
  # IPv6 anycast network blocks
"
  
  # Add IPv6 blocks
  for block in "${IPV6_BLOCKS[@]}"; do
    config+="  route $block blackhole;
"
  done
  
  config+="}"
  
  # Upload configuration to server
  echo "$config" | ssh -i "$SSH_KEY_PATH" "root@$ip" "cat > /etc/bird/conf.d/ibgp_client.conf"
  
  # Update main configuration to include the file
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Make sure the include statement is in bird.conf
    if ! grep -q 'include \"/etc/bird/conf.d/ibgp_.*\\.conf\";' /etc/bird/bird.conf; then
      echo 'include \"/etc/bird/conf.d/ibgp_*.conf\";' >> /etc/bird/bird.conf
    fi
    
    # Apply configuration
    birdc configure || {
      echo 'Failed to apply configuration, checking syntax:'
      birdc -c 'configure check' || true
    }
  "
  
  echo -e "${GREEN}iBGP client configuration created on $server.${NC}"
}

# Function to verify iBGP sessions
verify_ibgp() {
  echo -e "${BLUE}Verifying iBGP sessions...${NC}"
  
  # Give BIRD some time to establish sessions
  echo -e "${YELLOW}Waiting 10 seconds for iBGP sessions to establish...${NC}"
  sleep 10
  
  for server in "${!SERVER_IPS[@]}"; do
    local ip=${SERVER_IPS[$server]}
    
    echo -e "${BLUE}Checking iBGP status on $server ($ip)...${NC}"
    
    ssh -i "$SSH_KEY_PATH" "root@$ip" "
      echo 'BIRD protocols status:'
      birdc show protocols | grep -A 1 'BGP' || echo 'No BGP protocols found'
      
      echo ''
      echo 'BIRD routes from iBGP:'
      birdc show route protocol ibgp_* || echo 'No iBGP routes found'
    "
  done
}

# Main function
main() {
  echo -e "${BLUE}Starting iBGP configuration over WireGuard mesh network...${NC}"
  echo -e "${YELLOW}Using internal ASN $INTERNAL_ASN for iBGP mesh${NC}"
  echo -e "${YELLOW}Using public ASN $PUBLIC_ASN for external BGP${NC}"
  
  # Define route reflector
  RR_SERVER="lax"  # LAX is our primary location
  
  # Ensure BIRD is installed on all servers
  for server in "${!SERVER_IPS[@]}"; do
    ensure_bird "$server"
  done
  
  # Configure route reflector (LAX)
  create_rr_config "$RR_SERVER"
  
  # Configure clients (all other servers)
  for server in "${!SERVER_IPS[@]}"; do
    if [ "$server" != "$RR_SERVER" ]; then
      create_client_config "$server" "$RR_SERVER"
    fi
  done
  
  # Verify iBGP sessions
  verify_ibgp
  
  echo -e "${GREEN}iBGP configuration completed successfully!${NC}"
  echo -e "${YELLOW}Each server is now configured to announce:${NC}"
  for block in "${IPV4_BLOCKS[@]}"; do
    echo -e "  - $block (IPv4)"
  done
  for block in "${IPV6_BLOCKS[@]}"; do
    echo -e "  - $block (IPv6)"
  done
  echo -e "${YELLOW}Next steps:${NC}"
  echo -e "1. Set up looking glass for route verification"
  echo -e "2. Implement path prepending for geographic optimization"
}

# Run the main function
main