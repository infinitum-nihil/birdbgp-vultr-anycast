#!/bin/bash
# fix_lax_bird_id.sh - Sets explicit router ID for LAX server only

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed

# LAX server details
LAX_IP="149.248.2.74"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Fixing BIRD router ID on LAX (${LAX_IP})...${NC}"

ssh -i "$SSH_KEY_PATH" root@${LAX_IP} "
  # Set explicit router ID in BIRD configuration using the public IP
  PUBLIC_IP=${LAX_IP}
  if grep -q 'router id from' /etc/bird/bird.conf; then
    sed -i \"s|router id from .*|router id \$PUBLIC_IP;|\" /etc/bird/bird.conf
  else
    sed -i \"s|^router id .*;|router id \$PUBLIC_IP;|\" /etc/bird/bird.conf
  fi
  
  # Make sure firewall allows BGP traffic
  iptables -A INPUT -p tcp --dport 179 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 179 -j ACCEPT
  
  # Allow all traffic on WireGuard interface
  iptables -A INPUT -i wg0 -j ACCEPT
  iptables -A OUTPUT -o wg0 -j ACCEPT
  iptables -A FORWARD -i wg0 -j ACCEPT
  iptables -A FORWARD -o wg0 -j ACCEPT
  
  # Restart BIRD
  systemctl restart bird
  
  # Check if BIRD is running
  if systemctl is-active bird &> /dev/null; then
    echo 'BIRD successfully restarted with new router ID'
  else
    echo 'BIRD failed to start after setting router ID:'
    systemctl status bird
  fi
"

echo -e "${GREEN}BIRD router ID fix completed for LAX!${NC}"

# Check BGP status
echo -e "${BLUE}Checking BGP status on LAX (${LAX_IP})...${NC}"

ssh -i "$SSH_KEY_PATH" root@${LAX_IP} "
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