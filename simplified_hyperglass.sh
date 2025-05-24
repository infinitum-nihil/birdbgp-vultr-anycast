#\!/bin/bash

# Deploy a simpler Hyperglass configuration directly
# Created: 2025-05-23

SERVER_IP="149.248.2.74"

echo "Creating directories and BIRD proxy script on LAX..."
ssh root@$SERVER_IP "mkdir -p /etc/hyperglass/data /var/run/bird && chmod 755 /var/run/bird"

# Create a simple BIRD socket proxy script
cat > hyperglass-bird-simple << 'EOFSCRIPT'
#\!/bin/bash
# Simple proxy script for BIRD
if [[ "$2" == "show" || "$2" == "show protocol" || "$2" == "show protocols" ]]; then
  birdc "$2 $3 $4 $5"
else
  echo "Error: Command not allowed"
  exit 1
fi
EOFSCRIPT

chmod +x hyperglass-bird-simple
scp hyperglass-bird-simple root@$SERVER_IP:/usr/local/bin/hyperglass-bird
ssh root@$SERVER_IP "chmod +x /usr/local/bin/hyperglass-bird"

# Try a direct bird container approach
cat > direct-hyperglass.yml << 'EOFDOCKER'
version: '3.8'

networks:
  lg_network:
    driver: bridge

services:
  bird-proxy:
    image: alpine:latest
    container_name: bird-proxy
    restart: unless-stopped
    command: sh -c "apk add --no-cache bird && birdc show protocols"
    volumes:
      - /var/run/bird:/var/run/bird
    networks:
      - lg_network

  looking-glass:
    image: pierky/bird-looking-glass:latest
    container_name: looking-glass
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - PAGE_TITLE=AS27218 Infinitum Nihil Looking Glass
      - PAGE_DESC=This service provides real-time visibility into our global BGP routing infrastructure.
    depends_on:
      - bird-proxy
    networks:
      - lg_network
EOFDOCKER

scp direct-hyperglass.yml root@$SERVER_IP:/root/

echo "Starting simpler Hyperglass container on LAX..."
ssh root@$SERVER_IP "cd /root && docker-compose -f direct-hyperglass.yml up -d"
ssh root@$SERVER_IP "docker ps"

echo "Setup complete - check if the looking glass is accessible"
