#!/bin/bash
# Script to add IPv6 connectivity to IPv4-only servers
source "$(dirname "$0")/.env"

# Define server IPs
EWR_IP="66.135.18.138"  # Primary
MIA_IP="149.28.108.180"  # Secondary
ORD_IP="66.42.113.101"   # Tertiary

# Define server IDs from deployment_state.json
EWR_ID=$(jq -r '.ipv4_instances[0].id' deployment_state.json)
MIA_ID=$(jq -r '.ipv4_instances[1].id' deployment_state.json)
ORD_ID=$(jq -r '.ipv4_instances[2].id' deployment_state.json)

echo "=== Adding IPv6 Connectivity to Servers ==="
echo "This script will enable IPv6 on the following servers:"
echo "1. Primary (EWR): $EWR_IP (ID: $EWR_ID)"
echo "2. Secondary (MIA): $MIA_IP (ID: $MIA_ID)"
echo "3. Tertiary (ORD): $ORD_IP (ID: $ORD_ID)"
echo

# Confirm before proceeding
read -p "Are you sure you want to proceed? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
  echo "Operation canceled."
  exit 1
fi

# Function to enable IPv6 for a server
configure_ipv6() {
  local server_id=$1
  local server_ip=$2
  local server_name=$3
  
  echo
  echo "=== Configuring IPv6 for $server_name ($server_ip) ==="
  
  # First, check if IPv6 is already enabled on the instance
  echo "Checking if IPv6 is already enabled..."
  ipv6_info=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" "$VULTR_API_ENDPOINT/instances/$server_id")
  
  # Check if IPv6 is enabled
  ipv6_enabled=$(echo "$ipv6_info" | jq -r '.instance.v6_main_ip != ""')
  
  if [[ "$ipv6_enabled" == "true" ]]; then
    # IPv6 is already enabled, get the IPv6 address
    ipv6_address=$(echo "$ipv6_info" | jq -r '.instance.v6_main_ip')
    ipv6_network=$(echo "$ipv6_info" | jq -r '.instance.v6_network')
    ipv6_network_size=$(echo "$ipv6_info" | jq -r '.instance.v6_network_size')
    
    echo "IPv6 is already enabled on this server:"
    echo "  Main IPv6: $ipv6_address"
    echo "  IPv6 Network: $ipv6_network/$ipv6_network_size"
  else
    # IPv6 is not enabled, enable it through the Vultr API
    echo "IPv6 is not enabled on this server. Enabling IPv6..."
    
    # Enable IPv6 on the instance (Vultr API doesn't directly support this via API)
    echo "Note: IPv6 enablement through API is not directly supported by Vultr."
    echo "Please enable IPv6 for this instance through the Vultr control panel:"
    echo "1. Go to https://my.vultr.com/"
    echo "2. Navigate to your instance: $server_name ($server_ip)"
    echo "3. Click 'Settings' > 'IPv6' > 'Enable IPv6'"
    echo "4. After enabling, run this script again to configure the server"
    
    return 1
  fi
  
  # Configure IPv6 on the server
  echo "Configuring IPv6 on the server..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip << EOF
    # Add IPv6 configuration to network interfaces
    echo "Adding IPv6 configuration..."
    
    # First check if the server has the IPv6 address configured
    if ip -6 addr show | grep -q "$ipv6_address"; then
      echo "IPv6 address $ipv6_address is already configured"
    else
      # Determine the network interface
      MAIN_IF=\$(ip -br link | grep -v 'lo' | head -1 | awk '{print \$1}')
      echo "Adding IPv6 address $ipv6_address to interface \$MAIN_IF"
      
      # Add IPv6 address to the interface
      ip -6 addr add $ipv6_address/$ipv6_network_size dev \$MAIN_IF
      
      # Make the configuration persistent
      if [ -d /etc/netplan ]; then
        # Ubuntu 18.04+ uses netplan
        echo "Configuring netplan for IPv6..."
        cat > /etc/netplan/60-ipv6.yaml << NETPLAN
network:
  version: 2
  ethernets:
    \$MAIN_IF:
      dhcp6: false
      addresses:
        - $ipv6_address/$ipv6_network_size
      routes:
        - to: ::/0
          via: ${ipv6_network%::*}::1
NETPLAN
        netplan apply
      elif [ -f /etc/network/interfaces ]; then
        # Older systems use /etc/network/interfaces
        echo "Configuring /etc/network/interfaces for IPv6..."
        if ! grep -q "iface \$MAIN_IF inet6" /etc/network/interfaces; then
          cat >> /etc/network/interfaces << NETCONF
# IPv6 configuration
iface \$MAIN_IF inet6 static
  address $ipv6_address
  netmask $ipv6_network_size
  gateway ${ipv6_network%::*}::1
NETCONF
        fi
        ifdown \$MAIN_IF && ifup \$MAIN_IF
      fi
    fi
    
    # Verify IPv6 configuration
    echo "Verifying IPv6 configuration..."
    ip -6 addr show
    ip -6 route show
    
    # Test IPv6 connectivity
    echo "Testing IPv6 connectivity..."
    ping6 -c 3 2001:19f0:ffff::1 || echo "Cannot ping the BGP peer yet"
EOF
  
  # Restart BIRD on the server to pick up the new IPv6 configuration
  echo "Restarting BIRD to pick up the new IPv6 configuration..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "systemctl restart bird"
  
  # Wait for the BGP sessions to establish
  echo "Waiting for BGP sessions to establish..."
  sleep 10
  
  # Check BGP status
  echo "Checking BGP status..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols | grep -E 'vultr|Name'"
  
  echo "=== IPv6 configuration completed for $server_name ==="
  echo
  
  # Save the IPv6 address to a file
  echo "$ipv6_address" > "${server_name}_ipv6.txt"
  echo "IPv6 address saved to ${server_name}_ipv6.txt"
}

# Configure IPv6 on each server
configure_ipv6 "$EWR_ID" "$EWR_IP" "ewr-ipv4-primary"
configure_ipv6 "$MIA_ID" "$MIA_IP" "mia-ipv4-secondary"
configure_ipv6 "$ORD_ID" "$ORD_IP" "ord-ipv4-tertiary"

echo "IPv6 configuration process completed for all servers."
echo "Run ./check_bgp_status_2.sh to verify BGP status with IPv6."