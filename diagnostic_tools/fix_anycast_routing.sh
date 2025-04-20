#\!/bin/bash
# Script to fix anycast routing and advertisement

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create fix script
cat > /tmp/fix_anycast_routing.sh << 'FIXSCRIPT'
#\!/bin/bash
set -e

echo "Fixing anycast routing and BGP advertisement..."

# Check current IP configuration
echo "Current IP configuration:"
ip addr show dummy0
ip route list  < /dev/null |  grep 192.30.120.10

# Check if the anycast IP is correctly advertised
echo "Checking BGP routes:"
birdc show route | grep 192.30.120.10

# Create a temporary file with the correct protocol configuration
cat > /tmp/bgp_anycast.conf << 'BIRDCONF'
# Anycast network definitions
protocol direct anycast {
    interface "dummy0";
    ipv4 {
        import all;
        export none;
    };
    ipv6 {
        import all;
        export none;
    };
}

# Make sure these routes are exported to BGP
protocol static static_routes {
    ipv4 {
        export all;
    };
    route 192.30.120.10/32 via "dummy0";
    ipv6 {
        export all;
    };
    route 2620:71:4000::c01e:780a/128 via "dummy0";
}

# Add to the BGP export filter to ensure anycast routes are advertised
BIRDCONF

# Check if the anycast configurations already exist in the bird config
if \! grep -q "protocol direct anycast" /etc/bird/bird.conf; then
    echo "Adding anycast direct protocol to bird configuration..."
    cat /tmp/bgp_anycast.conf >> /etc/bird/bird.conf
fi

# Check if we need to modify the export filter in BGP protocols
if \! grep -q "export where source = RTS_STATIC" /etc/bird/bird.conf; then
    echo "Updating BGP export filters..."
    sed -i 's/export all;/export where source = RTS_STATIC || source = RTS_DEVICE;/' /etc/bird/bird.conf
fi

# Make sure the dummy interface is correctly set up
echo "Ensuring dummy interface is correctly configured..."
if \! ip link show dummy0 &>/dev/null; then
    echo "Creating dummy0 interface"
    modprobe dummy
    ip link add dummy0 type dummy
    ip link set dummy0 up
fi

# Verify anycast IP addresses are assigned to dummy0
if \! ip addr show dummy0 | grep -q "192.30.120.10"; then
    echo "Adding anycast IPv4 to dummy0"
    ip addr add 192.30.120.10/32 dev dummy0
fi

if \! ip addr show dummy0 | grep -q "2620:71:4000::c01e:780a"; then
    echo "Adding anycast IPv6 to dummy0"
    ip -6 addr add 2620:71:4000::c01e:780a/128 dev dummy0
fi

# Make sure the netplan configuration is correct
mkdir -p /etc/netplan
cat > /etc/netplan/60-anycast.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    dummy0:
      match:
        name: dummy0
      addresses:
        - 192.30.120.10/32
        - 2620:71:4000::c01e:780a/128
NETPLAN

# Apply netplan configuration
netplan apply

# Make sure iptables is correctly configured for the anycast IPs
echo "Ensuring firewall allows traffic to anycast IPs..."

# Check if anycast-specific rules exist
if \! iptables -L INPUT | grep -q "192.30.120.10"; then
    echo "Adding iptables rules for anycast IP..."
    iptables -A INPUT -d 192.30.120.10 -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -d 192.30.120.10 -p tcp --dport 443 -j ACCEPT
    
    # Save iptables rules
    iptables-save > /etc/iptables/rules.v4
fi

# Restart BIRD to apply new configuration
echo "Restarting BIRD service..."
systemctl restart bird

# Wait for BIRD to start
sleep 5

# Verify that the routes are correctly advertised
echo "Verifying BGP routes after restart:"
birdc show route | grep 192.30.120.10
birdc show protocols | grep BGP

echo "Verifying anycast IP is correctly configured:"
ip addr show dummy0
ip route get 192.30.120.10

echo "Anycast routing fix completed."
FIXSCRIPT

chmod +x /tmp/fix_anycast_routing.sh

# Upload and execute on LAX server
echo "Uploading anycast routing fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_anycast_routing.sh root@$LAX_IP:/tmp/fix_anycast_routing.sh

echo "Executing anycast routing fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_anycast_routing.sh"

echo "Anycast routing fix completed. Please allow time for BGP routes to propagate."
