#\!/bin/bash
# Script to fix BGP password and restart BIRD service

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Verify VULTR_BGP_PASSWORD is set
if [ -z "$VULTR_BGP_PASSWORD" ]; then
  echo "Error: VULTR_BGP_PASSWORD is not set in .env file"
  exit 1
fi

echo "Using BGP password from .env: ${VULTR_BGP_PASSWORD:0:3}***${VULTR_BGP_PASSWORD:(-3)}"

# Create fix script with proper password variable substitution
cat > /tmp/fix_bgp_password.sh << FIXSCRIPT
#\!/bin/bash
set -e

echo "Fixing BGP password in BIRD configuration..."

# Replace placeholder with actual password from environment variable
sed -i 's/password "your_bgp_password";/password "${VULTR_BGP_PASSWORD}";/g' /etc/bird/bird.conf

# Verify the change was made
echo "Verifying change:"
grep -A1 password /etc/bird/bird.conf

echo "Restarting BIRD service..."
systemctl restart bird

# Wait for BGP sessions to establish
echo "Waiting for BGP sessions to establish..."
sleep 10

echo "Checking BGP session status after restart:"
birdc show protocols  < /dev/null |  grep BGP

echo "BGP password fix completed."
FIXSCRIPT

chmod +x /tmp/fix_bgp_password.sh

# Upload and execute on LAX server
echo "Uploading BGP password fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_bgp_password.sh root@$LAX_IP:/tmp/fix_bgp_password.sh

echo "Executing BGP password fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash -c 'VULTR_BGP_PASSWORD=\"$VULTR_BGP_PASSWORD\" bash /tmp/fix_bgp_password.sh'"

echo "BGP password fix completed. Please check if BGP sessions are established now."
