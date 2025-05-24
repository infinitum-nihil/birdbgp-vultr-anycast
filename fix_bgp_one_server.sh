#!/bin/bash
# fix_bgp_one_server.sh - Fix BGP configuration on a specific server

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

# Check if server argument is provided
if [ $# -lt 1 ]; then
  echo "Usage: $0 <server_name>"
  echo "Server name must be one of: lax, ord, mia, ewr"
  exit 1
fi

SERVER=$1

if [[ ! ${SERVER_IPS[$SERVER]} ]]; then
  echo "Error: Invalid server name '$SERVER'. Must be one of: lax, ord, mia, ewr"
  exit 1
fi

SERVER_IP=${SERVER_IPS[$SERVER]}
WG_IP=${WG_IPS[$SERVER]}

# Determine if route reflector
IS_ROUTE_REFLECTOR=false
if [ "$SERVER" = "lax" ]; then
  IS_ROUTE_REFLECTOR=true
fi

echo -e "${BLUE}Fixing BGP configuration on $SERVER ($SERVER_IP)...${NC}"

# Creating main BIRD configuration
cat > /tmp/bird.conf << EOF
# BIRD Internet Routing Daemon Configuration
# Server: $SERVER

# Logging
log syslog all;
log stderr all;

# Force router ID to external IP
router id $SERVER_IP;

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

# Global definitions for all files
define VULTR_ASN = $VULTR_ASN;
define OUR_ASN = $OUR_ASN;
define OUR_IPV4_PREFIX = $OUR_IPV4_PREFIX;
define OUR_IPV6_PREFIX = $OUR_IPV6_PREFIX;
define LOCAL_IP = $SERVER_IP;

# Include other configuration files
include "/etc/bird/vultr.conf";
include "/etc/bird/ibgp.conf";
include "/etc/bird/static.conf";
EOF

# Creating Vultr BGP configuration
cat > /tmp/vultr.conf << EOF
# Vultr BGP Configuration

# IPv4 BGP peering with Vultr
protocol bgp vultr4 {
  description "Vultr IPv4 BGP";
  local as OUR_ASN;
  source address LOCAL_IP;
  neighbor $VULTR_IPV4 as VULTR_ASN;
  multihop $VULTR_MULTIHOP;
  password "$VULTR_PASSWORD";
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
  description "Vultr IPv6 BGP";
  local as OUR_ASN;
  source address LOCAL_IP;
  neighbor $VULTR_IPV6 as VULTR_ASN;
  multihop $VULTR_MULTIHOP;
  password "$VULTR_PASSWORD";
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

# Creating static routes configuration
cat > /tmp/static.conf << EOF
# Static routes for the ARIN assigned ranges

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

# Create iBGP configuration
if [ "$IS_ROUTE_REFLECTOR" = true ]; then
  # Route reflector configuration (LAX)
  cat > /tmp/ibgp.conf << EOF
# iBGP Configuration for mesh network
# LAX serves as the route reflector

template bgp ibgp_clients {
  local as OUR_ASN;
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
  neighbor ${WG_IPS["ord"]} as OUR_ASN;
  description "iBGP to ORD";
}

protocol bgp ibgp_mia from ibgp_clients {
  neighbor ${WG_IPS["mia"]} as OUR_ASN;
  description "iBGP to MIA";
}

protocol bgp ibgp_ewr from ibgp_clients {
  neighbor ${WG_IPS["ewr"]} as OUR_ASN;
  description "iBGP to EWR";
}
EOF
else
  # Client configuration (ORD, MIA, EWR)
  cat > /tmp/ibgp.conf << EOF
# iBGP Configuration for mesh network
# Client configuration pointing to LAX as route reflector

protocol bgp ibgp_rr {
  local as OUR_ASN;
  neighbor ${WG_IPS["lax"]} as OUR_ASN;
  direct;
  description "iBGP to Route Reflector (LAX)";
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
fi

# Upload configuration files to the server
scp -i "$SSH_KEY_PATH" /tmp/bird.conf "root@$SERVER_IP:/etc/bird/bird.conf"
scp -i "$SSH_KEY_PATH" /tmp/vultr.conf "root@$SERVER_IP:/etc/bird/vultr.conf"
scp -i "$SSH_KEY_PATH" /tmp/static.conf "root@$SERVER_IP:/etc/bird/static.conf"
scp -i "$SSH_KEY_PATH" /tmp/ibgp.conf "root@$SERVER_IP:/etc/bird/ibgp.conf"

# Restart BIRD
ssh -i "$SSH_KEY_PATH" "root@$SERVER_IP" "
  echo 'Checking configuration syntax...'
  bird -p || true
  
  echo 'Restarting BIRD...'
  systemctl restart bird
  sleep 2
  systemctl status bird | grep Active
"

echo -e "${GREEN}BGP configuration fixed on $SERVER.${NC}"