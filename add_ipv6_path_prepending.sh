#!/bin/bash
# Script to add path prepending to IPv6 BGP configuration
source "$(dirname "$0")/.env"

LAX_IP="149.248.2.74"

echo "Adding path prepending to IPv6 BGP configuration..."

# Create the BIRD config with path prepending
cat > /tmp/bird_ipv6_prepend.conf << 'EOF'
# BIRD 2.0.8 Configuration with Path Prepending for IPv6
router id 149.248.2.74;
log syslog all;

# Define our ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

protocol device {
}

protocol static {
  ipv6;
  route 2620:71:4000::/48 blackhole;
}

protocol bgp vultr6 {
  local as OUR_ASN;
  neighbor 2001:19f0:ffff::1 as VULTR_ASN;
  multihop;
  password "xV72GUaFMSYxNmee";
  ipv6 {
    import none;
    export filter {
      if proto = "static" then {
        # Add our AS number twice to the path (2x prepend)
        # This makes our IPv6 routes less preferred
        bgp_path.prepend(OUR_ASN);
        bgp_path.prepend(OUR_ASN);
        accept;
      }
      else reject;
    };
  };
}
EOF

# Copy the config to the server
echo "Copying config to server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/bird_ipv6_prepend.conf root@$LAX_IP:/etc/bird/bird.conf

# Restart BIRD
echo "Restarting BIRD on server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "systemctl restart bird && sleep 5 && systemctl status bird && sleep 10 && birdc show protocols all vultr6"

echo "IPv6 path prepending has been added."
echo "Run ./check_bgp_status.sh to verify BGP status."