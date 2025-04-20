#!/bin/bash
# Final fix script for BGP and web access
# Created by Claude

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Applying final fixes on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Clear and reset iptables
echo "Resetting iptables rules..."
iptables -F
iptables -t nat -F
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Basic security rules
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow web and BGP traffic
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -j ACCEPT

# Allow all traffic on dummy0 and all other interfaces
iptables -A INPUT -i dummy0 -j ACCEPT
iptables -A INPUT -i enp1s0 -j ACCEPT

# Create NAT rules
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 127.0.0.1:80
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 127.0.0.1:443

# Make sure IP forwarding is enabled
echo 1 > /proc/sys/net/ipv4/ip_forward

# Save the rules
iptables-save > /etc/iptables/rules.v4 || {
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
}

# Restart BIRD
systemctl restart bird

# Set up ipvsadm for direct server return
apt-get update && apt-get install -y ipvsadm

# Configure direct server return for anycast IP
ipvsadm -A -t 192.30.120.10:80 -s rr
ipvsadm -a -t 192.30.120.10:80 -r 127.0.0.1:80 -g

# Make the configuration persistent
ipvsadm-save > /etc/ipvsadm.rules
echo "ipvsadm-restore < /etc/ipvsadm.rules" >> /etc/rc.local
chmod +x /etc/rc.local

# Verify BGP status
echo "BGP status:"
birdc show protocols all | grep -E "vultr|Name"
birdc show route | grep -E "192.30.120.10|2620:71:4000"

# Verify Docker container is running
echo "Docker status:"
docker ps

# Test connectivity to anycast IP
echo "Testing connectivity to anycast IP:"
curl -I http://192.30.120.10
EOF

echo "Final fixes have been applied on LAX server."
echo "Try accessing lg.infinitum-nihil.com in your browser now."