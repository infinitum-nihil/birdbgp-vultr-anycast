#!/bin/bash
# Final script to fix IPv6 BGP - with correct syntax for BIRD 2.0.8
source "$(dirname "$0")/.env"

LAX_IP="149.248.2.74"

echo "Creating final corrected BIRD configuration for IPv6 BGP..."

# Create updated BIRD config with correct syntax
cat > /tmp/bird_ipv6_final.conf << 'EOF'
# BIRD 2.0.8 Configuration for IPv6 BGP
# Final version with correct syntax

# Global configuration
router id 149.248.2.74;
log syslog all;
debug protocols all;

# Define our ASN and Vultr's ASN as variables
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

# Set the IPv6 prefix we're announcing
define OUR_PREFIX = 2620:71:4000::/48;

# Device protocol
protocol device {
  scan time 10;
}

# Direct protocol for interfaces
protocol direct {
  ipv6;
  interface "*";
}

# Kernel protocol - install routes to kernel
protocol kernel {
  ipv6 {
    export all;
  };
}

# Static route for our prefix
protocol static {
  ipv6;
  route OUR_PREFIX blackhole;
}

# BGP for IPv6
protocol bgp vultr6 {
  description "Vultr IPv6 BGP";
  local as OUR_ASN;
  neighbor 2001:19f0:ffff::1 as VULTR_ASN;
  multihop 2;
  password "xV72GUaFMSYxNmee";
  
  ipv6 {
    import none;
    export where source ~ [ RTS_STATIC ];
    next hop self;
  };
}
EOF

echo "Transferring config to IPv6 server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/bird_ipv6_final.conf root@$LAX_IP:/etc/bird/bird.conf

echo "Restarting BIRD service on IPv6 server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Clean up any previous state
systemctl stop bird
killall -9 bird || true
rm -rf /run/bird
mkdir -p /run/bird
chown bird:bird /run/bird

# Verify the config
echo "Testing configuration:"
bird -p

# Start BIRD
systemctl start bird
sleep 5

# Check status
echo "BIRD service status:"
systemctl status bird

# Check BGP status
echo "BGP protocol status:"
birdc show protocols all vultr6

# Allow more time for BGP to establish and check again
echo "Waiting 20 more seconds for BGP to stabilize..."
sleep 20

echo "Final BGP status check:"
birdc show protocols all vultr6

# Check routes
echo "Checking IPv6 routes:"
birdc show route count
birdc show route protocol vultr6
EOF

echo "IPv6 BGP configuration has been finalized"
echo "Run ./check_bgp_status.sh to verify overall BGP status"