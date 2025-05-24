#!/bin/bash
# configure_temp_rr.sh - Temporarily configure ORD as a route reflector

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed
OUR_AS="27218"  # AS number

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
  ["ord"]="10.10.10.2"
  ["mia"]="10.10.10.3"
  ["ewr"]="10.10.10.4"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if LAX is reachable
check_lax() {
  echo -e "${BLUE}Checking if LAX is reachable...${NC}"
  if ping -c 1 -W 5 ${SERVER_IPS["lax"]} &>/dev/null; then
    echo -e "${GREEN}LAX is reachable! No need for temporary reconfiguration.${NC}"
    return 0
  else
    echo -e "${YELLOW}LAX is still unreachable. Proceeding with temporary reconfiguration.${NC}"
    return 1
  fi
}

# Configure ORD as a route reflector
configure_ord_as_rr() {
  local ord_ip=${SERVER_IPS["ord"]}
  
  echo -e "${BLUE}Configuring ORD as a temporary route reflector...${NC}"
  
  # Create a temporary file with the iBGP configuration for ORD
  local temp_config=$(mktemp)
  
  # Generate the configuration content
  cat > "$temp_config" << EOL
# iBGP Configuration for mesh network
# ORD is the temporary route reflector (10.10.10.2)

define SELF_ASN = ${OUR_AS};

template bgp ibgp_clients {
  local as SELF_ASN;
  rr client;
  rr cluster id 2;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}

# MIA iBGP peer
protocol bgp ibgp_mia {
  local as SELF_ASN;
  neighbor 10.10.10.3 as SELF_ASN;
  description "iBGP to MIA";
  rr client;
  rr cluster id 2;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}

# EWR iBGP peer
protocol bgp ibgp_ewr {
  local as SELF_ASN;
  neighbor 10.10.10.4 as SELF_ASN;
  description "iBGP to EWR";
  rr client;
  rr cluster id 2;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}
EOL

  # Upload the configuration
  scp -i "$SSH_KEY_PATH" "$temp_config" "root@$ord_ip:/etc/bird/ibgp.conf"
  
  # Remove the temporary file
  rm "$temp_config"
  
  # Restart BIRD on ORD
  ssh -i "$SSH_KEY_PATH" "root@$ord_ip" "
    # Set permissions
    chmod 640 /etc/bird/ibgp.conf
    chown bird:bird /etc/bird/ibgp.conf
    
    # Restart BIRD
    systemctl restart bird
    
    # Check if BIRD is running
    if systemctl is-active bird &> /dev/null; then
      echo 'BIRD successfully restarted on ORD (now route reflector)!'
    else
      echo 'BIRD failed to start on ORD:'
      systemctl status bird
    fi
  "
}

# Configure other servers to point to ORD
configure_client_for_ord() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Configuring $server to point to ORD as route reflector...${NC}"
  
  # Create a temporary file with the iBGP configuration
  local temp_config=$(mktemp)
  
  # Generate the configuration content
  cat > "$temp_config" << EOL
# iBGP Configuration for mesh network
# Client configuration pointing to ORD as temporary route reflector (10.10.10.2)

define SELF_ASN = ${OUR_AS};

protocol bgp ibgp_rr {
  local as SELF_ASN;
  neighbor 10.10.10.2 as SELF_ASN;  # ORD is now the route reflector
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
  description "iBGP to Route Reflector (ORD)";
}
EOL

  # Upload the configuration
  scp -i "$SSH_KEY_PATH" "$temp_config" "root@$ip:/etc/bird/ibgp.conf"
  
  # Remove the temporary file
  rm "$temp_config"
  
  # Restart BIRD
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Set permissions
    chmod 640 /etc/bird/ibgp.conf
    chown bird:bird /etc/bird/ibgp.conf
    
    # Restart BIRD
    systemctl restart bird
    
    # Check if BIRD is running
    if systemctl is-active bird &> /dev/null; then
      echo 'BIRD successfully restarted!'
    else
      echo 'BIRD failed to start:'
      systemctl status bird
    fi
  "
}

# Check BGP status
check_bgp_status() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Checking BGP status on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
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
  echo -e "${BLUE}Starting temporary route reflector configuration...${NC}"
  
  # Only proceed if LAX is unreachable
  if check_lax; then
    echo -e "${GREEN}LAX is reachable! No need for temporary reconfiguration.${NC}"
    exit 0
  fi
  
  # Configure ORD as a route reflector
  configure_ord_as_rr
  
  # Configure MIA and EWR to point to ORD
  for server in "mia" "ewr"; do
    configure_client_for_ord "$server"
  done
  
  # Wait for BGP sessions to establish
  echo -e "${YELLOW}Waiting 20 seconds for BGP sessions to establish...${NC}"
  sleep 20
  
  # Check BGP status on all servers except LAX
  for server in "ord" "mia" "ewr"; do
    check_bgp_status "$server"
  done
  
  echo -e "${GREEN}Temporary route reflector configuration completed!${NC}"
  echo -e "${YELLOW}Important: This is a temporary solution until LAX is back online.${NC}"
  echo -e "${YELLOW}Once LAX is back, run 'fix_bird_router_ids.sh lax' and then restore the original configuration.${NC}"
}

# Run the main function
main