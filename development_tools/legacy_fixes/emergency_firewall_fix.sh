#!/bin/bash
# emergency_firewall_fix.sh - Fix firewall rules to allow all traffic
# This script will disable all firewall restrictions

# Disable UFW if it's installed and active
if command -v ufw &> /dev/null; then
  echo "Disabling UFW..."
  ufw disable
fi

# Flush iptables rules
if command -v iptables &> /dev/null; then
  echo "Flushing iptables rules..."
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  
  # Set default policies to ACCEPT
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  
  # Save the rules
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
fi

# Disable CrowdSec if it's installed
if command -v cscli &> /dev/null; then
  echo "Disabling CrowdSec..."
  systemctl stop crowdsec
  systemctl disable crowdsec
fi

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
sysctl -p

# Restart networking and WireGuard
echo "Restarting networking..."
systemctl restart networking

if systemctl list-unit-files | grep -q wg-quick; then
  echo "Restarting WireGuard..."
  systemctl restart wg-quick@wg0
fi

# Restart BIRD if it's installed
if command -v birdc &> /dev/null; then
  echo "Restarting BIRD..."
  systemctl restart bird
fi

echo "Emergency firewall fix completed at $(date)"
echo "Server is now accessible from all IPs"