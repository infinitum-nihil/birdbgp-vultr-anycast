#!/bin/bash
# Script to check BGP status on all instances

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

echo "========== BGP SERVERS STATUS =========="
echo "Primary (EWR): $EWR_IP"
echo "Secondary (MIA): $MIA_IP"
echo "Tertiary (ORD): $ORD_IP" 
echo "IPv6 (LAX): $LAX_IP"
echo "========================================"

# Function to check BIRD status on a server
check_bird_status() {
  local server_ip=$1
  local server_name=$2
  
  echo
  echo "Checking $server_name BGP status on $server_ip..."
  echo "-----------------------------------------------"
  
  # Check if BIRD service is running
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "systemctl status bird | grep Active" || {
    echo "❌ ERROR: Could not connect to $server_name ($server_ip) or BIRD service not running"
    return 1
  }
  
  # Get BIRD protocol status
  echo
  echo "BIRD Protocol Status:"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols | grep -E 'vultr|Name'" || {
    echo "❌ ERROR: Could not get BIRD protocol status"
    return 1
  }

  # Check BGP route counts
  echo
  echo "BGP Routes:"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show route count" || {
    echo "❌ ERROR: Could not get route counts"
    return 1
  }
  
  # Get route details
  echo
  echo "Route Details:"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show route | head -10" || {
    echo "❌ ERROR: Could not get route details"
    return 1
  }
  
  # Check floating IP configuration
  echo
  echo "Network Interfaces (check for floating IPs):"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip addr | grep -E 'inet |inet6' | grep -v '127.0.0.1' | grep -v '::1'" || {
    echo "❌ ERROR: Could not check network interfaces"
    return 1
  }
  
  echo
  echo "✅ $server_name BGP status check completed"
  return 0
}

# Check each server
check_bird_status "$EWR_IP" "Primary (EWR)"
check_bird_status "$MIA_IP" "Secondary (MIA)"  
check_bird_status "$ORD_IP" "Tertiary (ORD)"
check_bird_status "$LAX_IP" "IPv6 (LAX)"

echo
echo "BGP status check completed for all servers"
echo
echo "To restart BGP on any server, use: ssh root@<server_ip> systemctl restart bird"
echo "To test failover, stop BGP on the primary: ssh root@$EWR_IP systemctl stop bird"