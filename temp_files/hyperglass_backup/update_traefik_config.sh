#!/bin/bash
# Script to update Traefik configuration to use all interfaces and obtain a new certificate

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Updating Traefik configuration on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Backup the original docker-compose.yml
cp /opt/traefik/docker-compose.yml /opt/traefik/docker-compose.yml.bak

# Update docker-compose.yml to use all interfaces
cat > /opt/traefik/docker-compose.yml << 'EOC'
services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/traefik/config:/config:ro
      - /opt/traefik/data:/data
      - /opt/traefik/logs:/logs
    command:
      - "--configfile=/config/traefik.yml"
    labels:
      - "traefik.enable=true"
      # Dashboard
      - "traefik.http.routers.traefik.rule=Host(`traefik.infinitum-nihil.com`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.middlewares=admin-auth"

networks:
  proxy:
    name: proxy
    external: false
EOC

# Remove the existing acme.json file to force certificate renewal
rm -f /opt/traefik/data/acme.json

# Start Traefik
cd /opt/traefik && docker-compose down && docker-compose up -d

# Wait for the acme.json file to be created
echo "Waiting for acme.json to be created and certificate to be obtained..."
sleep 30

# Check if the acme.json file exists and has content
if [ -s "/opt/traefik/data/acme.json" ]; then
  echo "Certificate generation started. The Let's Encrypt certificate will be obtained when DNS propagates."
else
  echo "acme.json file is empty or not created. Certificate renewal may have failed."
fi

# Check if Traefik is running
echo "Checking Traefik status:"
docker ps | grep traefik
EOF

echo "Traefik configuration has been updated."
echo "The Let's Encrypt certificate will be obtained automatically once the DNS change propagates."