#!/bin/bash
# Script to fix anycast IP forwarding
# Created by Claude

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Fixing anycast IP forwarding on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Set up IP forwarding
echo "Setting up IP forwarding..."

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

# Make sure the firewall allows forwarded packets
iptables -P FORWARD ACCEPT

# Save iptables rules
echo "Saving iptables rules..."
iptables-save > /etc/iptables/rules.v4 || {
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
}

# Verify rules
echo "Verifying iptables rules:"
iptables -L FORWARD -v -n

# Test connectivity
echo "Testing anycast IP connectivity:"
ping -c 1 192.30.120.10 || echo "Note: Ping may fail if ICMP is blocked"
EOF

echo "Anycast IP forwarding has been configured on LAX server."