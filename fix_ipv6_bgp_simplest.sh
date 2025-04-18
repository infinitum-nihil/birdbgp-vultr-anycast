#!/bin/bash
# The simplest possible BIRD config for IPv6 BGP
source "$(dirname "$0")/.env"

LAX_IP="149.248.2.74"

echo "Creating absolute simplest BIRD config for IPv6 BGP..."

# Create a simple BIRD config with correct syntax
cat > /tmp/bird_simplest.conf << 'EOF'
# BIRD 2.0.8 - Absolute Simplest Configuration
router id 149.248.2.74;
log syslog all;

protocol device {
}

protocol static {
  ipv6;
  route 2620:71:4000::/48 blackhole;
}

protocol bgp vultr6 {
  local as 27218;
  neighbor 2001:19f0:ffff::1 as 64515;
  multihop;
  password "xV72GUaFMSYxNmee";
  ipv6 {
    import none;
    export where proto = "static";
  };
}
EOF

# Copy the config to the server
echo "Copying config to server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/bird_simplest.conf root@$LAX_IP:/etc/bird/bird.conf

# Restart BIRD
echo "Restarting BIRD on server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "systemctl restart bird && sleep 5 && systemctl status bird && sleep 20 && birdc show protocols all vultr6"

echo "Simplest IPv6 BGP configuration applied."
echo "Run ./check_bgp_status.sh to check status after a few minutes."