#!/bin/bash
# Script to ensure BIRD is properly restarted on all servers

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# Get server IPs
MIA_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
ORD_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)

echo "Fixing BIRD on Secondary (MIA) server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$MIA_IP "
  echo 'Stopping BIRD...'
  systemctl stop bird
  
  # Make sure no leftover processes
  echo 'Checking for any remaining BIRD processes...'
  killall -9 bird || true
  
  echo 'Removing socket directory if exists...'
  rm -rf /run/bird
  
  echo 'Recreating socket directory...'
  mkdir -p /run/bird
  chown bird:bird /run/bird
  
  echo 'Starting BIRD...'
  systemctl start bird
  
  # Wait for BIRD to start
  sleep 5
  
  echo 'BIRD status:'
  systemctl status bird
  
  echo 'BGP status:'
  birdc show protocols vultr || echo 'Still unable to connect to BIRD socket'
"

echo "Fixing BIRD on Tertiary (ORD) server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$ORD_IP "
  echo 'Stopping BIRD...'
  systemctl stop bird
  
  # Make sure no leftover processes
  echo 'Checking for any remaining BIRD processes...'
  killall -9 bird || true
  
  echo 'Removing socket directory if exists...'
  rm -rf /run/bird
  
  echo 'Recreating socket directory...'
  mkdir -p /run/bird
  chown bird:bird /run/bird
  
  echo 'Starting BIRD...'
  systemctl start bird
  
  # Wait for BIRD to start
  sleep 5
  
  echo 'BIRD status:'
  systemctl status bird
  
  echo 'BGP status:'
  birdc show protocols vultr || echo 'Still unable to connect to BIRD socket'
"

echo "BIRD fixes applied. Now wait a minute and run ./check_bgp_status.sh to verify everything is working."