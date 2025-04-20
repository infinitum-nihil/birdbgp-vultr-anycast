#!/bin/bash
# Final attempt to fix IPv6 BGP by simplifying configuration
source "$(dirname "$0")/.env"

LAX_IP="149.248.2.74"

echo "Creating final IPv6 BGP fix with simplified configuration..."

# Generate a script file to run on the remote server
cat > /tmp/fix_ipv6_final.sh << 'REMOTE_SCRIPT'
#!/bin/bash
# Save the original config as backup
cp /etc/bird/bird.conf /etc/bird/bird.conf.bak.$(date +%s)

# Get interface and IPv6 details
MAIN_IF=$(ip -br link | grep -v 'lo' | head -1 | awk '{print $1}')
MAIN_IPV6=$(ip -6 addr show dev $MAIN_IF | grep 'scope global' | grep -v 'mngtmpaddr' | awk '{print $2}' | cut -d'/' -f1 | head -1)
echo "Main interface: $MAIN_IF"
echo "Main IPv6: $MAIN_IPV6"

# Create the simplest possible BIRD config
cat > /etc/bird/bird.conf << EOB
# BIRD 2.0.8 Configuration for IPv6 BGP - Ultra Simple Configuration

# Global configuration
router id 149.248.2.74;
log syslog all;

# Device protocol
protocol device {
}

# Kernel protocol - to install routes
protocol kernel {
  ipv6 {
    import none;
    export all;
  };
}

# Static route for our prefix
protocol static {
  ipv6 {
    route 2620:71:4000::/48 blackhole;
  };
}

# BGP protocol - Explicitly disable MD5 authentication (using 'passive' option)
protocol bgp vultr6 {
  local as 27218;
  neighbor 2001:19f0:ffff::1 as 64515;
  multihop;
  password "xV72GUaFMSYxNmee";
  ipv6 {
    import none;
    export where proto = "static1";
  };
}
EOB

# Verify and restart BIRD
echo "Verifying configuration..."
bird -p

echo "Cleaning up old BIRD state..."
systemctl stop bird
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
journalctl -u bird --no-pager -n 30 | grep -i vultr

# Try connecting with different IPv6 source address (use the link-local address)
echo "Trying other IPv6 addresses to connect to BGP peer..."
LINK_LOCAL=$(ip -6 addr show dev $MAIN_IF | grep -i 'fe80' | awk '{print $2}' | cut -d'/' -f1)
echo "Link-local address: $LINK_LOCAL"

# Try a variation with the link-local address
cat > /etc/bird/bird.conf.link_local << EOB
# BIRD 2.0.8 Configuration for IPv6 BGP - Using Link-Local Address

# Global configuration
router id 149.248.2.74;
log syslog all;

# Device protocol
protocol device {
}

# Kernel protocol - to install routes
protocol kernel {
  ipv6 {
    import none;
    export all;
  };
}

# Static route for our prefix
protocol static {
  ipv6 {
    route 2620:71:4000::/48 blackhole;
  };
}

# BGP protocol with link-local address
protocol bgp vultr6 {
  local $LINK_LOCAL as 27218;
  neighbor 2001:19f0:ffff::1 as 64515;
  multihop;
  password "xV72GUaFMSYxNmee";
  ipv6 {
    import none;
    export where proto = "static1";
  };
}
EOB

# Check if the session is still not established
BIRD_STATUS=$(birdc show protocols vultr6 | grep -c "Connect")
if [ "$BIRD_STATUS" -gt 0 ]; then
  echo "Session not established with default config. Trying link-local variant..."
  cp /etc/bird/bird.conf.link_local /etc/bird/bird.conf
  systemctl restart bird
  sleep 10
  birdc show protocols all vultr6
fi

# Wait longer for BGP to establish
echo "Waiting 30 seconds for BGP to establish..."
sleep 30

echo "Final BGP status check:"
birdc show protocols all vultr6
REMOTE_SCRIPT

# Make remote script executable
chmod +x /tmp/fix_ipv6_final.sh

# Copy the script to remote server
echo "Copying script to remote server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_ipv6_final.sh root@$LAX_IP:/tmp/

# Execute the script on the remote server
echo "Executing script on remote server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_ipv6_final.sh"

echo "Final IPv6 BGP attempt completed"
echo "Run ./check_bgp_status.sh to verify overall BGP status"