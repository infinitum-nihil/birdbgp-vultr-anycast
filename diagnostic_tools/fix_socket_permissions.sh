#!/bin/bash

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create fix script
cat > /tmp/fix_socket_permissions.sh << 'EOF'
#!/bin/bash
set -e

echo "Checking BIRD socket path and permissions..."
ls -la /var/run/bird.ctl || echo "Socket not found at /var/run/bird.ctl"
ls -la /var/run/bird/ || echo "No files in /var/run/bird/"
ls -la /var/run/bird/bird.ctl || echo "Socket not found at /var/run/bird/bird.ctl"

echo "Fixing BIRD socket permissions..."
chown -R bird:bird /var/run/bird/
chmod -R 775 /var/run/bird/

#!/bin/bash

# Check both possible socket locations
if [ -S "/var/run/bird.ctl" ]; then
  BIRD_SOCKET="/var/run/bird.ctl"
elif [ -S "/var/run/bird/bird.ctl" ]; then
  BIRD_SOCKET="/var/run/bird/bird.ctl"
else
  echo "Error: BIRD socket not found in standard locations"
  exit 1
fi

# Get command from stdin 
read -r command

# Pass to BIRD socket with error handling
echo "$command" | socat -t 5 - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null || 
  echo "Error: Failed to connect to BIRD socket"
BIRDSCRIPT


echo "Testing BIRD socket proxy..."
if [ -e "/var/run/bird.ctl" ] || [ -e "/var/run/bird/bird.ctl" ]; then
else
    echo "No BIRD socket found in standard locations"
fi

echo "Restarting BIRD service..."
systemctl restart bird


services:
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8001:8001"
    volumes:
      - /var/run/bird:/var/run/bird:ro
    labels:
    environment:

networks:
  proxy:
    external: true
DOCKER

docker compose up -d

echo "Checking container status..."
docker ps

echo "BIRD socket permissions and path fixed"
EOF

chmod +x /tmp/fix_socket_permissions.sh

# Upload and execute on LAX server
echo "Uploading socket fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_socket_permissions.sh root@$LAX_IP:/tmp/fix_socket_permissions.sh

echo "Executing socket fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_socket_permissions.sh"

echo "Socket permissions fixed"