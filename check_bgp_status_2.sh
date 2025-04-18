#!/bin/bash
# Script to check BGP status on all instances with BIRD 2.16.2

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

echo "Getting BGP instance information..."

# Get region information from .env file
if [ -z "$BGP_REGION_PRIMARY" ] || [ -z "$BGP_REGION_SECONDARY" ] || [ -z "$BGP_REGION_TERTIARY" ] || [ -z "$BGP_REGION_QUATERNARY" ]; then
  echo "Error: One or more BGP regions are not defined in .env file"
  echo "Please ensure BGP_REGION_PRIMARY, BGP_REGION_SECONDARY, BGP_REGION_TERTIARY, and BGP_REGION_QUATERNARY are set"
  exit 1
fi

# Set the IPs based on the region information from .env
PRIMARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_PRIMARY}-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
SECONDARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_SECONDARY}-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
TERTIARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_TERTIARY}-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
QUATERNARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_QUATERNARY}-ipv4-bgp-quaternary-1c1g_ipv4.txt" 2>/dev/null)

# Check if IPs were found
if [ -z "$PRIMARY_IP" ] || [ -z "$SECONDARY_IP" ] || [ -z "$TERTIARY_IP" ] || [ -z "$QUATERNARY_IP" ]; then
  echo "Error: Could not find all required IPs in IP files."
  echo "Found: PRIMARY(${BGP_REGION_PRIMARY})=$PRIMARY_IP, SECONDARY(${BGP_REGION_SECONDARY})=$SECONDARY_IP, TERTIARY(${BGP_REGION_TERTIARY})=$TERTIARY_IP, QUATERNARY(${BGP_REGION_QUATERNARY})=$QUATERNARY_IP"
  exit 1
fi

echo "========== BGP SERVERS STATUS =========="
echo "Primary (${BGP_REGION_PRIMARY}): $PRIMARY_IP"
echo "Secondary (${BGP_REGION_SECONDARY}): $SECONDARY_IP"
echo "Tertiary (${BGP_REGION_TERTIARY}): $TERTIARY_IP" 
echo "Quaternary (${BGP_REGION_QUATERNARY}): $QUATERNARY_IP"
echo "========================================"

# Function to check BIRD status on a server
check_bird_status() {
  local server_ip=$1
  local server_name=$2
  
  echo
  echo "Checking $server_name BGP status on $server_ip..."
  echo "-----------------------------------------------"
  
  # Check BIRD version and status
  echo "BIRD Version and Status:"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "birdc show status | grep -E 'BIRD|up'" || {
    echo "❌ ERROR: Could not get BIRD status"
    return 1
  }
  
  # Get BGP protocol status - both IPv4 and IPv6
  echo
  echo "BGP Protocol Status:"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols | grep -E 'vultr|Name'" || {
    echo "❌ ERROR: Could not get BGP protocol status"
    return 1
  }
  
  # Get IPv4 BGP details
  echo
  echo "IPv4 BGP Details:"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols all vultr_v4 | head -20" || {
    echo "❌ ERROR: Could not get IPv4 BGP details"
  }
  
  # Get IPv6 BGP details (all servers now support IPv6)
  echo
  echo "IPv6 BGP Details:"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols all vultr_v6 | head -20" || {
    echo "❌ ERROR: Could not get IPv6 BGP details"
  }

  # Check BGP route counts
  echo
  echo "BGP Routes:"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show route count" || {
    echo "❌ ERROR: Could not get route counts"
    return 1
  }
  
  # Check network interfaces for IP addresses
  echo
  echo "Network Interfaces (check for IP addresses):"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip addr show | grep -E 'inet |inet6' | grep -v '127.0.0.1' | grep -v '::1'" || {
    echo "❌ ERROR: Could not check network interfaces"
    return 1
  }
  
  echo
  echo "✅ $server_name BGP status check completed"
  return 0
}

# Check each server
check_bird_status "$PRIMARY_IP" "Primary (${BGP_REGION_PRIMARY})"
check_bird_status "$SECONDARY_IP" "Secondary (${BGP_REGION_SECONDARY})"  
check_bird_status "$TERTIARY_IP" "Tertiary (${BGP_REGION_TERTIARY})"
check_bird_status "$QUATERNARY_IP" "Quaternary (${BGP_REGION_QUATERNARY})"

echo
echo "BGP status check completed for all servers"
echo
echo "To restart BGP on any server, use: ssh root@<server_ip> systemctl restart bird"
echo "To test failover, stop BGP on the primary: ssh root@$PRIMARY_IP systemctl stop bird"