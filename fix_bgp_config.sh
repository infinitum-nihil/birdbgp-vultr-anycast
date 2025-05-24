#!/bin/bash
# fix_bgp_config.sh - Ensure all BGP servers have consistent and correct configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_nt_infinitum-nihil_com"

# BGP Configuration details from STATEMENT_OF_FACTS
OUR_ASN=27218
VULTR_ASN=64515
VULTR_IPV4="169.254.169.254"
VULTR_IPV6="2001:19f0:ffff::1"
VULTR_PASSWORD="xV72GUaFMSYxNmee"
VULTR_MULTIHOP=2
OUR_IPV4_PREFIX="192.30.120.0/23"
OUR_IPV6_PREFIX="2620:71:4000::/48"

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ord"]="66.42.113.101"
  ["mia"]="149.28.108.180"
  ["ewr"]="66.135.18.138"
)

# WireGuard IPs
declare -A WG_IPS=(
  ["lax"]="10.10.10.1"  # Primary - Los Angeles (HQ)
  ["ord"]="10.10.10.2"  # Secondary - Chicago (closest to LA)
  ["mia"]="10.10.10.3"  # Tertiary - Miami (farther from LA)
  ["ewr"]="10.10.10.4"  # Quaternary - Newark (farthest from LA)
)

# Function to fix a server's BGP configuration
fix_bgp_config() {
  local server=$1
  local server_ip=${SERVER_IPS[$server]}
  local wg_ip=${WG_IPS[$server]}
  local is_route_reflector=false
  
  if [ "$server" = "lax" ]; then
    is_route_reflector=true
  fi
  
  echo -e "${BLUE}Fixing BGP configuration on $server ($server_ip)...${NC}"
  
  # Create the main BIRD configuration
  ssh -i "$SSH_KEY_PATH" "root@$server_ip" "
    echo 'Creating BIRD main configuration...'
    cat > /etc/bird/bird.conf << 'EOF'
# BIRD Internet Routing Daemon Configuration
# Server: $server

# Logging
log syslog all;
log stderr all;

# Force router ID to external IP
router id $server_ip;

# Basic protocols
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
include \"/etc/bird/vultr.conf\";
include \"/etc/bird/ibgp.conf\";
include \"/etc/bird/static.conf\";
EOF
    
    echo 'Creating Vultr BGP configuration...'
    cat > /etc/bird/vultr.conf << 'EOF'
# Vultr BGP Configuration

# Define Vultr's ASN and ours
define VULTR_ASN = $VULTR_ASN;
define OUR_ASN = $OUR_ASN;

# Define our ARIN assigned address blocks
define OUR_IPV4_PREFIX = $OUR_IPV4_PREFIX;
define OUR_IPV6_PREFIX = $OUR_IPV6_PREFIX;

# Define our local IP for source addressing
define LOCAL_IP = $server_ip;

# IPv4 BGP peering with Vultr
protocol bgp vultr4 {
  description \"Vultr IPv4 BGP\";
  local as OUR_ASN;
  source address LOCAL_IP;
  neighbor $VULTR_IPV4 as VULTR_ASN;
  multihop $VULTR_MULTIHOP;
  password \"$VULTR_PASSWORD\";
  ipv4 {
    import none;
    export filter {
      if net = OUR_IPV4_PREFIX then accept;
      reject;
    };
    next hop self;
  };
}

# IPv6 BGP peering with Vultr
protocol bgp vultr6 {
  description \"Vultr IPv6 BGP\";
  local as OUR_ASN;
  source address LOCAL_IP;
  neighbor $VULTR_IPV6 as VULTR_ASN;
  multihop $VULTR_MULTIHOP;
  password \"$VULTR_PASSWORD\";
  ipv6 {
    import none;
    export filter {
      if net = OUR_IPV6_PREFIX then accept;
      reject;
    };
    next hop self;
  };
}
EOF
    
    echo 'Creating static routes configuration...'
    cat > /etc/bird/static.conf << 'EOF'
# Static routes for the ARIN assigned ranges

# Define our ARIN assigned address blocks
define OUR_IPV4_PREFIX = $OUR_IPV4_PREFIX;
define OUR_IPV6_PREFIX = $OUR_IPV6_PREFIX;

# Static routes for the anycast ranges
protocol static static_anycast_v4 {
  ipv4 {
    preference 110;
  };
  route OUR_IPV4_PREFIX reject;
}

protocol static static_anycast_v6 {
  ipv6 {
    preference 110;
  };
  route OUR_IPV6_PREFIX reject;
}
EOF
  "
  
  # Create iBGP configuration - different for route reflector vs clients
  if [ "$is_route_reflector" = true ]; then
    # Route reflector configuration (LAX)
    ssh -i "$SSH_KEY_PATH" "root@$server_ip" "
      echo 'Creating iBGP route reflector configuration...'
      cat > /etc/bird/ibgp.conf << 'EOF'
# iBGP Configuration for mesh network
# LAX serves as the route reflector

define SELF_ASN = $OUR_ASN;

template bgp ibgp_clients {
  local as SELF_ASN;
  rr client;
  rr cluster id 1;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
  ipv6 {
    import all;
    export all;
    next hop self;
  };
}

protocol bgp ibgp_ord from ibgp_clients {
  neighbor ${WG_IPS['ord']} as SELF_ASN;
  description \"iBGP to ORD\";
}

protocol bgp ibgp_mia from ibgp_clients {
  neighbor ${WG_IPS['mia']} as SELF_ASN;
  description \"iBGP to MIA\";
}

protocol bgp ibgp_ewr from ibgp_clients {
  neighbor ${WG_IPS['ewr']} as SELF_ASN;
  description \"iBGP to EWR\";
}
EOF
    "
  else
    # Client configuration (ORD, MIA, EWR)
    ssh -i "$SSH_KEY_PATH" "root@$server_ip" "
      echo 'Creating iBGP client configuration...'
      cat > /etc/bird/ibgp.conf << 'EOF'
# iBGP Configuration for mesh network
# Client configuration pointing to LAX as route reflector

define SELF_ASN = $OUR_ASN;

protocol bgp ibgp_rr {
  local as SELF_ASN;
  neighbor ${WG_IPS['lax']} as SELF_ASN;
  direct;
  description \"iBGP to Route Reflector (LAX)\";
  ipv4 {
    import all;
    export all;
  };
  ipv6 {
    import all;
    export all;
  };
}
EOF
    "
  fi
  
  # Restart BIRD
  ssh -i "$SSH_KEY_PATH" "root@$server_ip" "
    echo 'Restarting BIRD...'
    systemctl restart bird
    sleep 2
    systemctl status bird | grep Active
  "
  
  echo -e "${GREEN}BGP configuration fixed on $server.${NC}"
}

# Main function
main() {
  echo -e "${BLUE}Starting BGP configuration fix on all servers...${NC}"
  echo
  
  for server in "${!SERVER_IPS[@]}"; do
    fix_bgp_config "$server"
    echo
  done
  
  echo -e "${GREEN}BGP configuration fixed on all servers.${NC}"
  echo -e "${YELLOW}Wait a few minutes for BGP sessions to establish, then check status with:${NC}"
  echo "bash /home/normtodd/birdbgp/check_bgp_sessions.sh"
}

# Run the main function
main