#!/bin/bash
# Script to fix Hyperglass container on LAX

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create the fix script
cat > /tmp/fix_hyperglass.sh << 'EOF'
#!/bin/bash
set -e

echo "Fixing Hyperglass container..."
cd /opt/hyperglass

# Stop existing container
docker compose down

# Create a new Dockerfile with the correct entry point
cat > Dockerfile << 'DOCKERFILE'
FROM python:3.12-alpine

WORKDIR /app

RUN apk add --no-cache build-base libffi-dev git gcc musl-dev g++ cairo-dev \
    jpeg-dev zlib-dev freetype-dev lcms2-dev openjpeg-dev tiff-dev tk-dev tcl-dev \
    py3-pip cargo libpq-dev openssl-dev rust

# Set environment variables
ENV PYTHONFAULTHANDLER=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=random \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_DEFAULT_TIMEOUT=100

# Copy current directory contents to container
COPY . .

# Install hyperglass
RUN pip install uvicorn[standard] 
RUN pip install .

EXPOSE 8001

# Instead of using python -m hyperglass, use uvicorn directly
CMD ["uvicorn", "hyperglass.api:app", "--host", "0.0.0.0", "--port", "8001"]
DOCKERFILE

# Create docker-compose.yml
cat > docker-compose.yml << 'COMPOSE'
services:
  hyperglass:
    build: .
    container_name: hyperglass
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8001:8001"
    volumes:
      - /etc/hyperglass:/etc/hyperglass:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hyperglass-sub.rule=Host(`lg.infinitum-nihil.com`)"
      - "traefik.http.routers.hyperglass-sub.entrypoints=websecure"
      - "traefik.http.routers.hyperglass-sub.tls.certresolver=letsencrypt"
      - "traefik.http.services.hyperglass.loadbalancer.server.port=8001"
    environment:
      - HYPERGLASS_CONFIG_DIR=/etc/hyperglass

networks:
  proxy:
    external: true
COMPOSE

# Build and start container
echo "Building fixed Hyperglass container..."
docker compose build
docker compose up -d

# Check status
echo "Checking container status:"
docker ps

# Check logs
echo "Container logs:"
docker logs hyperglass

# Test BIRD socket proxy
echo "Testing BIRD socket proxy:"
echo "show status" | /usr/local/bin/hyperglass-bird
EOF

chmod +x /tmp/fix_hyperglass.sh

# Upload and execute
echo "Uploading fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_hyperglass.sh root@$LAX_IP:/tmp/fix_hyperglass.sh

echo "Executing fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_hyperglass.sh"

echo "Fix completed"