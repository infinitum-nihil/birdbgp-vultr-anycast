#\!/bin/bash
# Script to fix blackhole routes and BGP configuration

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create fix script
cat > /tmp/fix_blackhole_routes.sh << 'FIXSCRIPT'
#\!/bin/bash
set -e

echo "Fixing blackhole routes and BGP configuration..."

# Make a backup of the current configuration
cp /etc/bird/bird.conf /etc/bird/bird.conf.bak.$(date +%s)

# Replace blackhole routes with proper device routes
sed -i 's/route 192.30.120.10\/32 blackhole;/route 192.30.120.10\/32 via "dummy0";/' /etc/bird/bird.conf
sed -i 's/route 2620:71:4000::c01e:780a\/128 blackhole;/route 2620:71:4000::c01e:780a\/128 via "dummy0";/' /etc/bird/bird.conf

# Verify export filter for BGP
if grep -q export_bgp_filter /etc/bird/bird.conf; then
  echo "Checking export_bgp_filter configuration..."
  
  # Ensure the filter allows our anycast IPs
  if \! grep -q "192.30.120.10/32" /etc/bird/bird.conf; then
    echo "Adding anycast IPv4 to export filter..."
    sed -i '/export_bgp_filter/,/}/s/}/    if net ~ [ 192.30.120.10\/32 ] then accept;\n}/' /etc/bird/bird.conf
  fi
  
  if \! grep -q "2620:71:4000::c01e:780a/128" /etc/bird/bird.conf; then
    echo "Adding anycast IPv6 to export filter..."
    sed -i '/export_bgp_filter/,/}/s/}/    if net ~ [ 2620:71:4000::c01e:780a\/128 ] then accept;\n}/' /etc/bird/bird.conf
  fi
fi

# Verify changes
echo "Verifying route configuration:"
grep -A2 "route 192.30.120.10" /etc/bird/bird.conf
grep -A2 "route 2620:71:4000" /etc/bird/bird.conf

# Restart BIRD to apply changes
echo "Restarting BIRD service..."
systemctl restart bird

# Wait for BGP sessions to establish
echo "Waiting for BGP sessions to establish..."
sleep 10

# Check BGP session status
echo "Checking IPv4 BGP session status:"
birdc show protocols all vultr4  < /dev/null |  grep -A5 "BGP state"

echo "Checking IPv6 BGP session status:"
birdc show protocols all vultr6 | grep -A5 "BGP state"

# Check routes
echo "Checking routes:"
birdc show route where net ~ [ 192.30.120.10/32 ]
birdc show route where net ~ [ 2620:71:4000::c01e:780a/128 ]

echo "Route fix completed."
FIXSCRIPT

chmod +x /tmp/fix_blackhole_routes.sh

# Upload and execute on LAX server
echo "Uploading route fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_blackhole_routes.sh root@$LAX_IP:/tmp/fix_blackhole_routes.sh

echo "Executing route fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_blackhole_routes.sh"

echo "Route fix completed. Checking if BGP sessions are now established."
