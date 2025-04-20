#\!/bin/bash
# Script to fix BGP peering with correct Vultr BGP neighbor IPs

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create fix script
cat > /tmp/fix_vultr_bgp.sh << 'FIXSCRIPT'
#\!/bin/bash
set -e

echo "Fixing BGP configuration for correct Vultr BGP neighbors..."

# Make a backup of the current configuration
cp /etc/bird/bird.conf /etc/bird/bird.conf.bak.$(date +%s)

# Update IPv4 BGP configuration
sed -i 's/neighbor 149.248.2.1 as 64515;/neighbor 169.254.169.254 as 64515;\nmultihop 2;/' /etc/bird/bird.conf

# Verify IPv6 BGP has multihop set to 2
if \! grep -q "multihop 2" /etc/bird/bird.conf; then
  sed -i 's/multihop;/multihop 2;/' /etc/bird/bird.conf
fi

# Verify the changes
echo "Verifying changes:"
echo "IPv4 BGP configuration:"
grep -A5 "protocol bgp vultr4" /etc/bird/bird.conf

echo "IPv6 BGP configuration:"
grep -A5 "protocol bgp vultr6" /etc/bird/bird.conf

# Restart BIRD to apply changes
echo "Restarting BIRD service..."
systemctl restart bird

# Wait for BGP sessions to establish
echo "Waiting for BGP sessions to establish..."
sleep 15

# Check BGP session status
echo "Checking BGP sessions:"
birdc show protocols  < /dev/null |  grep BGP

echo "BGP configuration fix completed."
FIXSCRIPT

chmod +x /tmp/fix_vultr_bgp.sh

# Upload and execute on LAX server
echo "Uploading BGP fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_vultr_bgp.sh root@$LAX_IP:/tmp/fix_vultr_bgp.sh

echo "Executing BGP fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_vultr_bgp.sh"

echo "BGP configuration fix completed. Checking if BGP sessions are now established."
