#!/bin/bash
# Script to build Hyperglass container manually on LAX

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create deployment script
cat > /tmp/build_hyperglass.sh << 'EOF'
#!/bin/bash
set -e

echo "Creating custom Hyperglass Docker setup..."
cd /opt/hyperglass

# Clean up existing docker-compose files
rm -f docker-compose.yml compose.yaml

# Create a simple Dockerfile 
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

CMD ["python", "-m", "hyperglass", "--no-ui-build"]
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
echo "Building Hyperglass container..."
docker compose down || true
docker compose build --no-cache
docker compose up -d

# Check status
echo "Checking container status..."
docker ps | grep hyperglass

# Check logs
echo "Container logs:"
docker logs hyperglass
EOF

chmod +x /tmp/build_hyperglass.sh

# Upload and execute
echo "Uploading build script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/build_hyperglass.sh root@$LAX_IP:/tmp/build_hyperglass.sh

echo "Executing build script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/build_hyperglass.sh"

echo "Build process completed"