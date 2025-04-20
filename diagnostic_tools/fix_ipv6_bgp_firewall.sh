#!/bin/bash
# Script to fix IPv6 BGP by updating firewall and source address
source "$(dirname "$0")/.env"

LAX_IP="149.248.2.74"

echo "Creating final IPv6 BGP fix with firewall updates..."

# Generate a script file to run on the remote server
cat > /tmp/fix_ipv6_remote.sh << 'REMOTE_SCRIPT'
#!/bin/bash
# Add firewall rules for BGP
echo "Adding firewall rules for BGP..."
ufw allow 179/tcp
ufw allow 179/tcp comment 'BGP'
ufw allow out 179/tcp
ufw route allow proto tcp from any to any port 179
ufw reload

# Get interface and IPv6 details
MAIN_IF=$(ip -br link | grep -v 'lo' | head -1 | awk '{print $1}')
MAIN_IPV6=$(ip -6 addr show dev $MAIN_IF | grep 'scope global' | grep -v 'mngtmpaddr' | awk '{print $2}' | cut -d'/' -f1 | head -1)
echo "Main interface: $MAIN_IF"
echo "Main IPv6: $MAIN_IPV6"

# Create BIRD config with source address
cat > /etc/bird/bird.conf << EOB
# BIRD 2.0.8 Configuration for IPv6 BGP
# With explicit source address and firewall fixes

# Global configuration
router id 149.248.2.74;
log syslog all;
debug protocols all;

# Define our ASN and Vultr's ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;
define OUR_PREFIX = 2620:71:4000::/48;
define OUR_IPv6 = $MAIN_IPV6;

# Device protocol
protocol device {
  scan time 10;
}

# Direct protocol for interfaces
protocol direct {
  ipv6;
  interface "*";
}

# Kernel protocol
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

# BGP for IPv6 with source address
protocol bgp vultr6 {
  description "Vultr IPv6 BGP";
  local OUR_IPv6 as OUR_ASN;
  neighbor 2001:19f0:ffff::1 as VULTR_ASN;
  
  multihop 2;
  password "xV72GUaFMSYxNmee";
  
  ipv6 {
    import none;
    export where source ~ [ RTS_STATIC ];
    next hop self;
  };
}
EOB

# Verify and restart BIRD
echo "Verifying configuration..."
bird -p

echo "Cleaning up old BIRD state..."
systemctl stop bird
killall -9 bird || true
rm -rf /run/bird
mkdir -p /run/bird
chown bird:bird /run/bird

echo "Starting BIRD service..."
systemctl start bird
sleep 5

# Check status
echo "BIRD service status:"
systemctl status bird | grep Active

# Check BGP status
echo "BGP protocol status:"
birdc show protocols all vultr6

# Test BGP port connectivity
echo "Testing BGP port connectivity:"
nc -zv 2001:19f0:ffff::1 179

# Check logs for connection issues
echo "Checking logs for BGP issues:"
journalctl -u bird --no-pager -n 50 | grep -i vultr

# Wait longer for BGP to establish
echo "Waiting 30 seconds for BGP to establish..."
sleep 30

echo "Final BGP status check:"
birdc show protocols all vultr6
REMOTE_SCRIPT

# Make remote script executable
chmod +x /tmp/fix_ipv6_remote.sh

# Copy the script to remote server
echo "Copying script to remote server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_ipv6_remote.sh root@$LAX_IP:/tmp/

# Execute the script on the remote server
echo "Executing script on remote server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_ipv6_remote.sh"

echo "IPv6 BGP firewall and source address fix completed"
echo "Run ./check_bgp_status.sh to verify overall BGP status"