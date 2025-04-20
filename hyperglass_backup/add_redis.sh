#!/bin/bash
# Script to add Redis to LAX server for Hyperglass

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create Redis deployment script
cat > /tmp/add_redis.sh << 'EOF'
#!/bin/bash
set -e

echo "Adding Redis to Docker Compose configuration..."

# Update Hyperglass Docker Compose file to include Redis
cat > /opt/hyperglass/docker-compose.yml << 'DOCKER'
services:
  hyperglass:
    image: hyperglass-hyperglass
    container_name: hyperglass
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8001:8001"
    volumes:
      - /etc/hyperglass:/etc/hyperglass:ro
      - /var/run/bird.ctl:/var/run/bird.ctl:ro
      - /usr/local/bin/hyperglass-bird:/usr/local/bin/hyperglass-bird:ro
    environment:
      - HYPERGLASS_CONFIG_DIR=/etc/hyperglass
      - REDIS_HOST=redis
    depends_on:
      - redis
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hyperglass-sub.rule=Host(`lg.infinitum-nihil.com`)"
      - "traefik.http.routers.hyperglass-sub.entrypoints=websecure"
      - "traefik.http.routers.hyperglass-sub.tls.certresolver=letsencrypt"
      - "traefik.http.services.hyperglass.loadbalancer.server.port=8001"

  redis:
    image: redis:alpine
    container_name: redis
    restart: unless-stopped
    networks:
      - proxy
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes

networks:
  proxy:
    external: true

volumes:
  redis_data:
DOCKER

# Restart the containers
cd /opt/hyperglass
docker compose down
docker compose up -d

echo "Checking container status..."
docker ps

echo "Redis added to Hyperglass deployment"
EOF

chmod +x /tmp/add_redis.sh

# Upload and execute on LAX server
echo "Uploading Redis setup script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/add_redis.sh root@$LAX_IP:/tmp/add_redis.sh

echo "Executing Redis setup script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/add_redis.sh"

echo "Redis added"