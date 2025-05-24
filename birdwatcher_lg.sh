#\!/bin/bash

# Deploy Birdwatcher with simple HTML frontend
# Created: 2025-05-23

SERVER_IP="149.248.2.74"

echo "Setting up Birdwatcher on LAX..."

# Stop existing containers
ssh root@$SERVER_IP "docker stop hyperglass redis || true"
ssh root@$SERVER_IP "docker rm hyperglass redis || true"
ssh root@$SERVER_IP "docker network rm hyperglass_network || true"

# Install Go
ssh root@$SERVER_IP "apt-get update && apt-get install -y golang-go git"

# Install Birdwatcher
ssh root@$SERVER_IP "
cd /root
git clone https://github.com/ecix/birdwatcher.git
cd birdwatcher
export GOPATH=/root/go
mkdir -p \$GOPATH
go build

# Create configuration
mkdir -p /etc/birdwatcher
cat > /etc/birdwatcher/birdwatcher.conf << 'EOFCONFIG'
{
  \"server\": {
    \"listen\": \"0.0.0.0:8000\"
  },
  
  \"bird\": {
    \"socket\": \"/var/run/bird/bird.ctl\",
    \"socket6\": \"/var/run/bird/bird6.ctl\"
  },
  
  \"cache\": {
    \"status\": true,
    \"ttl\": 30,
    \"refresh_threads\": 4,
    \"refresh_interval\": 15
  },
  
  \"frontend\": {
    \"enabled\": true,
    \"title\": \"AS27218 Infinitum Nihil Looking Glass\"
  }
}
EOFCONFIG

# Create systemd service file
cat > /etc/systemd/system/birdwatcher.service << 'EOFSERVICE'
[Unit]
Description=Birdwatcher Looking Glass
After=network.target bird.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/birdwatcher
ExecStart=/root/birdwatcher/birdwatcher -config /etc/birdwatcher/birdwatcher.conf
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSERVICE

# Enable and start service
systemctl daemon-reload
systemctl enable birdwatcher
systemctl start birdwatcher

# Configure firewall
ufw allow 8000/tcp comment 'Allow Birdwatcher Looking Glass'

# Setup nginx as a proxy
apt-get install -y nginx
cat > /etc/nginx/sites-available/birdwatcher << 'EOFNGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOFNGINX

ln -sf /etc/nginx/sites-available/birdwatcher /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
"

echo "Checking Birdwatcher service status..."
ssh root@$SERVER_IP "systemctl status birdwatcher"

echo "Birdwatcher Looking Glass should now be accessible at http://$SERVER_IP"
