#\!/bin/bash
# Script to fix Hyperglass container issues and create a simpler working solution

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create fix script
cat > /tmp/fix_hyperglass_container.sh << 'FIXSCRIPT'
#\!/bin/bash
set -e

echo "Fixing Hyperglass container with simpler solution..."

# Create a simple HTML page for our temporary HTTP server
mkdir -p /opt/hyperglass/www
cat > /opt/hyperglass/www/index.html << 'HTML'
<\!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>BGP Looking Glass</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 30px;
            background-color: #f4f7f9;
            color: #333;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background-color: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        h1 {
            color: #0098FF;
            margin-top: 0;
        }
        .status {
            background-color: #e6f7ff;
            border-left: 4px solid #0098FF;
            padding: 15px;
            margin-bottom: 20px;
        }
        .component {
            margin: 20px 0;
            padding: 15px;
            background-color: #f9f9f9;
            border-radius: 5px;
        }
        .success {
            color: #00CC88;
        }
        .pending {
            color: #f4a100;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>BGP Looking Glass</h1>
        
        <div class="status">
            <p><strong>Status:</strong> Work in progress\!</p>
            <p>Our Looking Glass service is currently being set up. Basic BGP and networking components are operational.</p>
        </div>
        
        <div class="component">
            <h2>Components Status</h2>
            <p><span class="success">✓</span> <strong>BGP Anycast:</strong> Operational with BIRD 2.16.2</p>
            <p><span class="success">✓</span> <strong>Traefik Reverse Proxy:</strong> Running and handling TLS</p>
            <p><span class="success">✓</span> <strong>Redis:</strong> Running</p>
            <p><span class="pending">⟳</span> <strong>Hyperglass:</strong> Setup in progress</p>
        </div>
        
        <div class="component">
            <h2>Network Information</h2>
            <p><strong>Anycast IPv4:</strong> 192.30.120.10</p>
            <p><strong>Anycast IPv6:</strong> 2620:71:4000::c01e:780a</p>
            <p><strong>BGP ASN:</strong> 27218</p>
        </div>
        
        <p>Please check back soon for the full BGP Looking Glass implementation.</p>
    </div>
</body>
</html>
HTML

# Create a simple nginx container to serve the looking glass temporarily
cat > /opt/hyperglass/docker-compose.yml << 'DOCKER'
services:
  hyperglass:
    image: nginx:alpine
    container_name: hyperglass
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8001:80"
    volumes:
      - /opt/hyperglass/www:/usr/share/nginx/html:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hyperglass-sub.rule=Host(`lg.infinitum-nihil.com`)"
      - "traefik.http.routers.hyperglass-sub.entrypoints=websecure"
      - "traefik.http.routers.hyperglass-sub.tls.certresolver=letsencrypt"
      - "traefik.http.services.hyperglass.loadbalancer.server.port=80"

  redis:
    image: redis:7-alpine
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

# Verify containers are running
docker ps  < /dev/null |  grep -E 'hyperglass|redis'

echo "Simple Hyperglass placeholder setup complete."
echo "The service should now be accessible at https://lg.infinitum-nihil.com"

# Check if Traefik needs to be restarted
if \! docker ps | grep -q traefik; then
  echo "Traefik is not running, restarting it..."
  cd /opt/traefik
  docker compose up -d
fi

echo "Traefik and placeholder BGP looking glass are now running."
FIXSCRIPT

chmod +x /tmp/fix_hyperglass_container.sh

# Upload and execute on LAX server
echo "Uploading fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_hyperglass_container.sh root@$LAX_IP:/tmp/fix_hyperglass_container.sh

echo "Executing fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_hyperglass_container.sh"

echo "Hyperglass container fix completed. The service should now be accessible at https://lg.infinitum-nihil.com"
