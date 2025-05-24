#!/bin/bash
# fix_ibgp_config.sh - Fixes iBGP configuration issues

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed
INTERNAL_ASN=65001  # Private ASN for iBGP mesh

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# WireGuard IPs - These are the CORRECT mappings from actual WireGuard configs
declare -A WG_IPS=(
  ["lax"]="10.10.10.4" # Actual WireGuard IP from config
  ["ewr"]="10.10.10.1" # Actual WireGuard IP from config
  ["mia"]="10.10.10.2" # Actual WireGuard IP from config
  ["ord"]="10.10.10.3" # Actual WireGuard IP from config
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to fix route reflector configuration
fix_rr_config() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  local wg_ip=${WG_IPS[$server]}
  
  echo -e "${BLUE}Fixing iBGP route reflector configuration on $server ($ip)...${NC}"
  
  # Generate new RR configuration
  local config="# iBGP Route Reflector Configuration
# Created by fix_ibgp_config.sh on $(date)
# Server: $server ($ip)
# WireGuard IP: $wg_ip

# Define route reflector cluster ID
define rr_cluster_id = 1;

# Template for iBGP clients
template bgp ibgp_clients {
  local as $INTERNAL_ASN;
  rr client;
  rr cluster id rr_cluster_id;
  hold time 60;
  keepalive time 20;
  multihop;
  interface \"wg0\";  # Use WireGuard interface for iBGP
  direct;
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
  
  # Add peer configurations
  for peer in "${!SERVER_IPS[@]}"; do
    if [ "$peer" != "$server" ]; then
      local peer_wg_ip=${WG_IPS[$peer]}
      
      config+="protocol bgp ibgp_$peer from ibgp_clients {
  neighbor $peer_wg_ip as $INTERNAL_ASN;
  description \"iBGP to $peer\";
}

"
    fi
  done
  
  # Add static routes
  config+="# Static routes for anycast network blocks
protocol static static_anycast_v4 {
  ipv4 {
    export all;
  };
  
  # IPv4 anycast network blocks
  route 192.30.120.0/23 blackhole;
}

protocol static static_anycast_v6 {
  ipv6 {
    export all;
  };
  
  # IPv6 anycast network blocks
  route 2620:71:4000::/48 blackhole;
}"
  
  # Upload configuration
  echo "$config" | ssh -i "$SSH_KEY_PATH" "root@$ip" "cat > /etc/bird/conf.d/ibgp_rr.conf"
  
  # Restart BIRD
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Make sure BGP port is allowed through firewall
    iptables -D INPUT -p tcp --dport 179 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport 179 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p tcp --dport 179 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 179 -j ACCEPT
    
    # Make sure all WireGuard traffic is allowed
    iptables -D INPUT -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o wg0 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -i wg0 -j ACCEPT
    iptables -A OUTPUT -o wg0 -j ACCEPT
    
    # Restart BIRD
    systemctl restart bird
    
    # Check if BIRD is running
    if systemctl is-active bird &> /dev/null; then
      echo 'BIRD successfully restarted'
    else
      echo 'BIRD failed to start:'
      systemctl status bird
    fi
  "
}

# Function to fix client configuration
fix_client_config() {
  local server=$1
  local rr_server=$2
  local ip=${SERVER_IPS[$server]}
  local wg_ip=${WG_IPS[$server]}
  local rr_wg_ip=${WG_IPS[$rr_server]}
  
  echo -e "${BLUE}Fixing iBGP client configuration on $server ($ip)...${NC}"
  
  # Generate new client configuration
  local config="# iBGP Client Configuration
# Created by fix_ibgp_config.sh on $(date)
# Server: $server ($ip)
# WireGuard IP: $wg_ip
# Route Reflector: $rr_server (${WG_IPS[$rr_server]})

# iBGP session to route reflector
protocol bgp ibgp_$rr_server {
  local as $INTERNAL_ASN;
  neighbor $rr_wg_ip as $INTERNAL_ASN;
  hold time 60;
  keepalive time 20;
  multihop;
  interface \"wg0\";  # Use WireGuard interface for iBGP
  direct;
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
  route 192.30.120.0/23 blackhole;
}

protocol static static_anycast_v6 {
  ipv6 {
    export all;
  };
  
  # IPv6 anycast network blocks
  route 2620:71:4000::/48 blackhole;
}"
  
  # Upload configuration
  echo "$config" | ssh -i "$SSH_KEY_PATH" "root@$ip" "cat > /etc/bird/conf.d/ibgp_client.conf"
  
  # Restart BIRD
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Make sure BGP port is allowed through firewall
    iptables -D INPUT -p tcp --dport 179 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport 179 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p tcp --dport 179 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 179 -j ACCEPT
    
    # Make sure all WireGuard traffic is allowed
    iptables -D INPUT -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o wg0 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -i wg0 -j ACCEPT
    iptables -A OUTPUT -o wg0 -j ACCEPT
    
    # Restart BIRD
    systemctl restart bird
    
    # Check if BIRD is running
    if systemctl is-active bird &> /dev/null; then
      echo 'BIRD successfully restarted'
    else
      echo 'BIRD failed to start:'
      systemctl status bird
    fi
  "
}

# Function to check BGP status
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
  echo -e "${BLUE}Starting iBGP configuration fix...${NC}"
  
  # Define route reflector (LAX)
  RR_SERVER="lax"
  
  # Fix route reflector configuration
  fix_rr_config "$RR_SERVER"
  
  # Fix client configurations
  for server in "${!SERVER_IPS[@]}"; do
    if [ "$server" != "$RR_SERVER" ]; then
      fix_client_config "$server" "$RR_SERVER"
    fi
  done
  
  # Wait for BGP sessions to establish
  echo -e "${YELLOW}Waiting 20 seconds for BGP sessions to establish...${NC}"
  sleep 20
  
  # Check BGP status on all servers
  for server in "${!SERVER_IPS[@]}"; do
    check_bgp_status "$server"
  done
  
  echo -e "${GREEN}iBGP configuration fix completed!${NC}"
}

# Run the main function
main