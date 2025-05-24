#!/bin/bash
# fix_mia_ibgp.sh - Reconfigure MIA to connect back to LAX as the route reflector

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed
OUR_AS="27218"  # AS number

# MIA server details
MIA_IP="149.28.108.180"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Reconfiguring MIA to connect to LAX as route reflector...${NC}"

# Create a temporary file with the iBGP configuration
temp_config=$(mktemp)

# Generate the configuration content
cat > "$temp_config" << EOL
# iBGP Configuration for mesh network
# Client configuration pointing to LAX as route reflector (10.10.10.1)

define SELF_ASN = ${OUR_AS};

protocol bgp ibgp_rr {
  local as SELF_ASN;
  neighbor 10.10.10.1 as SELF_ASN;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
  description "iBGP to Route Reflector (LAX)";
}
EOL

# Upload the configuration
scp -i "$SSH_KEY_PATH" "$temp_config" "root@$MIA_IP:/etc/bird/ibgp.conf"

# Remove the temporary file
rm "$temp_config"

# Restart BIRD
ssh -i "$SSH_KEY_PATH" "root@$MIA_IP" "
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
  
  # Check BGP status
  echo -e '\nBGP protocol status:'
  birdc show protocols | grep -A 1 BGP
  
  # Check router ID
  echo -e '\nRouter ID:'
  birdc show status | grep 'Router ID'
"

echo -e "${GREEN}MIA reconfiguration completed!${NC}"