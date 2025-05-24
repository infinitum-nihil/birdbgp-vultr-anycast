#\!/bin/bash
# Script to fix Traefik configuration for proper domain name handling

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create fix script
cat > /tmp/fix_traefik_config.sh << 'FIXSCRIPT'
#\!/bin/bash
set -e

echo "Fixing Traefik configuration for proper domain name handling..."

# Verify Traefik configuration directory
if [ \! -d "/opt/traefik/config" ]; then
  echo "Traefik configuration directory not found\!"
  exit 1
fi

# Check if certResolver is properly configured in traefik.yml
if \! grep -q "certificatesResolvers:" /opt/traefik/config/traefik.yml; then
  echo "Certificate resolver not found in traefik.yml\!"
  exit 1
fi

# Print the current resolver configuration
echo "Current certificate resolver configuration:"
grep -A 10 "certificatesResolvers:" /opt/traefik/config/traefik.yml

# Update container labels to use the correct resolver
cd /opt/hyperglass
sed -i 's/certresolver=letsencrypt/certresolver=dnschallenge/g' docker-compose.yml || sed -i 's/certresolver=dnschallenge/certresolver=letsencrypt/g' docker-compose.yml

# Check if fix was applied
if grep -q "certresolver=letsencrypt" docker-compose.yml; then
  echo "Using letsencrypt resolver"
elif grep -q "certresolver=dnschallenge" docker-compose.yml; then
  echo "Using dnschallenge resolver"
else
  echo "No resolver found in hyperglass docker-compose.yml\!"
  exit 1
fi

# Remove acme.json to force certificate regeneration
echo "Removing old acme.json to force certificate regeneration..."
rm -f /opt/traefik/data/acme.json
touch /opt/traefik/data/acme.json
chmod 600 /opt/traefik/data/acme.json

# Restart containers to apply changes
echo "Restarting containers to apply changes..."
cd /opt/traefik
docker compose down
docker compose up -d

cd /opt/hyperglass
docker compose down
docker compose up -d

# Check status
echo "Container status:"
docker ps  < /dev/null |  grep -E 'traefik|hyperglass'

echo "Traefik fix completed."
echo "Please allow a few minutes for Traefik to obtain new certificates."
FIXSCRIPT

chmod +x /tmp/fix_traefik_config.sh

# Upload and execute on LAX server
echo "Uploading fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_traefik_config.sh root@$LAX_IP:/tmp/fix_traefik_config.sh

echo "Executing fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_traefik_config.sh"

echo "Traefik configuration fix completed. Please wait a few minutes for certificates to be generated."
