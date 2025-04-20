#!/bin/bash
# Script to fix BGP configuration on LAX server
# Created by Claude

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Fixing BGP configuration on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Create dummy0 interface if it doesn't exist
if ! ip link show dummy0 >/dev/null 2>&1; then
  echo "Creating dummy0 interface..."
  modprobe dummy
  ip link add dummy0 type dummy
  ip link set dummy0 up
  
  # Make sure it persists after reboot
  echo "dummy" > /etc/modules-load.d/dummy.conf
  echo "auto dummy0" > /etc/network/interfaces.d/dummy
  echo "iface dummy0 inet manual" >> /etc/network/interfaces.d/dummy
  echo "pre-up ip link add dummy0 type dummy" >> /etc/network/interfaces.d/dummy
  echo "up ip link set dummy0 up" >> /etc/network/interfaces.d/dummy
fi

# Add anycast IPs to dummy0 interface
echo "Adding anycast IPs to dummy0 interface..."
ip addr add 192.30.120.10/32 dev dummy0 2>/dev/null || true
ip -6 addr add 2620:71:4000::c01e:780a/128 dev dummy0 2>/dev/null || true

# Check if correct link-local address is used in BIRD config
current_linklocal=$(ip -6 addr show dev enp1s0 | grep -i 'fe80' | awk '{print $2}' | cut -d'/' -f1)
echo "Current link-local address: $current_linklocal"

# Update BIRD config if needed
if grep -q "fe80::5400:5dd:fe65:af4e" /etc/bird/bird.conf; then
  echo "Fixing incorrect link-local address in BIRD config..."
  sed -i "s|fe80::5400:5dd:fe65:af4e|$current_linklocal|g" /etc/bird/bird.conf
fi

# Restart BIRD
echo "Restarting BIRD..."
systemctl restart bird
sleep 5

# Check BIRD status
echo "BIRD service status:"
systemctl status bird | grep Active

# Check BGP sessions
echo "BGP protocol status:"
birdc show protocols all vultr4
echo ""
birdc show protocols all vultr6

# Check routes
echo "Checking if anycast IPs are being properly announced..."
birdc show route export vultr4 | grep -E "192.30.120.0/23|192.30.120.10/32"
birdc show route export vultr6 | grep -E "2620:71:4000::/48|2620:71:4000::c01e:780a/128"

# Check network interfaces
echo "Verifying network interfaces:"
ip addr show dev dummy0
EOF

echo "BGP fixes applied to LAX server."
echo "Run ./check_bgp_status.sh to verify the status of all BGP sessions."