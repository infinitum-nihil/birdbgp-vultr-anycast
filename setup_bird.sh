#!/bin/bash
# Script to install and configure BIRD on all instances
# Usage: ./setup_bird.sh [--yes]

# Check for auto-confirm option
AUTO_CONFIRM=false
if [ "$1" = "--yes" ]; then
  AUTO_CONFIRM=true
fi

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

echo "Getting BGP instance information..."

# Set the IPs directly based on the ID files we know exist
EWR_IP=$(cat "$(dirname "$0")/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
MIA_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
ORD_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Check if IPs were found
if [ -z "$EWR_IP" ] || [ -z "$MIA_IP" ] || [ -z "$ORD_IP" ] || [ -z "$LAX_IP" ]; then
  echo "Error: Could not find all required IPs in IP files."
  echo "Found: EWR=$EWR_IP, MIA=$MIA_IP, ORD=$ORD_IP, LAX=$LAX_IP"
  exit 1
fi

echo "========== BGP SERVERS SETUP =========="
echo "Primary (EWR): $EWR_IP"
echo "Secondary (MIA): $MIA_IP"
echo "Tertiary (ORD): $ORD_IP" 
echo "IPv6 (LAX): $LAX_IP"
echo "========================================"

# Function to install and configure BIRD on a server
setup_bird() {
  local server_ip=$1
  local server_name=$2
  local bird_conf=$3
  local is_ipv6=$4
  
  echo
  echo "Setting up BIRD on $server_name ($server_ip)..."
  echo "-----------------------------------------------"
  
  # Check if we can connect to the server
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "echo 'Connection successful'" || {
    echo "❌ ERROR: Could not connect to $server_name ($server_ip)"
    return 1
  }
  
  echo "1. Installing BIRD..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "apt-get update && apt-get install -y bird2" || {
    echo "❌ ERROR: Failed to install BIRD"
    return 1
  }
  
  echo "2. Creating BIRD configuration directory..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "mkdir -p /etc/bird" || {
    echo "❌ ERROR: Failed to create BIRD config directory"
    return 1
  }
  
  echo "3. Uploading BIRD configuration..."
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "$(dirname "$0")/$bird_conf" root@$server_ip:/etc/bird/bird.conf || {
    echo "❌ ERROR: Failed to upload BIRD configuration"
    return 1
  }
  
  echo "4. Setting up dummy interface for BGP..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
    modprobe dummy
    ip link add dummy0 type dummy || true
    ip link set dummy0 up
    echo 'dummy' >> /etc/modules || true
  " || {
    echo "❌ WARNING: Failed to set up dummy interface, it may already exist"
  }
  
  # For IPv6 server, we need to check the interface name first
  if [ "$is_ipv6" = "true" ]; then
    echo "5. Setting up IPv6 static route to Vultr's BGP server..."
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
      # Find the main interface
      MAIN_IF=\$(ip -br link | grep -v 'lo' | head -1 | awk '{print \$1}')
      echo \"Using interface \$MAIN_IF for IPv6 routing\"
      # Get the link-local address
      LINK_LOCAL=\$(ip -6 addr show dev \$MAIN_IF | grep -i 'fe80' | awk '{print \$2}' | cut -d'/' -f1)
      echo \"Using link-local address \$LINK_LOCAL\"
      # Update the BIRD config with the correct interface name
      sed -i \"s/route 2001:19f0:ffff::1\\/128 via \\\"eth0\\\";/route 2001:19f0:ffff::1\\/128 via \\\"\$MAIN_IF\\\";/g\" /etc/bird/bird.conf
    " || {
      echo "❌ WARNING: Failed to set up IPv6 static route, continuing anyway"
    }
  fi
  
  echo "6. Testing BIRD configuration..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
    bird -p
  " || {
    echo "❌ ERROR: BIRD configuration contains errors"
    return 1
  }
  
  echo "7. Starting BIRD service..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "
    systemctl enable bird
    systemctl restart bird
  " || {
    echo "❌ ERROR: Failed to start BIRD service"
    return 1
  }
  
  echo "8. Checking BIRD status..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "systemctl status bird" || {
    echo "❌ ERROR: BIRD service not running"
    return 1
  }
  
  echo "✅ BIRD setup completed on $server_name ($server_ip)"
  return 0
}

# Ask for confirmation unless auto-confirm is set
if [ "$AUTO_CONFIRM" != "true" ]; then
  echo
  read -p "This will install and configure BIRD on all servers. Continue? (y/n): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Setup cancelled."
    exit 0
  fi
fi

# Set up BIRD on each server
setup_bird "$EWR_IP" "Primary (EWR)" "ewr-ipv4-primary_bird.conf" "false"
setup_bird "$MIA_IP" "Secondary (MIA)" "mia-ipv4-secondary_bird.conf" "false"
setup_bird "$ORD_IP" "Tertiary (ORD)" "ord-ipv4-tertiary_bird.conf" "false"
setup_bird "$LAX_IP" "IPv6 (LAX)" "lax-ipv6_bird.conf" "true"

echo
echo "BIRD setup completed for all servers"
echo
echo "To check BGP status, run: ./check_bgp_status.sh"
echo "To test failover, stop BGP on the primary: ssh root@$EWR_IP systemctl stop bird"