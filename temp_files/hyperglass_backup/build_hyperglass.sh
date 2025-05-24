#!/bin/bash
# Script to build and set up hyperglass locally
# Following the manual installation method at https://hyperglass.dev/installation/manual

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Building hyperglass on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Stop existing services
systemctl stop hyperglass 2>/dev/null || true
docker stop hyperglass redis 2>/dev/null || true

# Install dependencies
apt-get update && apt-get install -y python3-pip python3-venv socat

# Create a Python virtual environment
mkdir -p /opt/hyperglass-venv
python3 -m venv /opt/hyperglass-venv

# Activate the environment and install hyperglass
source /opt/hyperglass-venv/bin/activate
pip install --upgrade pip
pip install hyperglass Redis

# Create configuration directory if it doesn't exist
mkdir -p /etc/hyperglass

# Start Redis using Docker
docker run -d --name redis --restart unless-stopped -p 127.0.0.1:6379:6379 redis:7-alpine

# Make sure the BIRD socket is accessible
if [ -S /var/run/bird.ctl ]; then
  chmod 666 /var/run/bird.ctl
  echo "BIRD socket permissions updated"
else
  echo "Warning: BIRD socket not found. Make sure BIRD is running."
fi

# Create the proxy script if it doesn't exist
if [ ! -f "/usr/local/bin/hyperglass-bird" ]; then
  echo "Creating BIRD proxy script..."
  cat > /usr/local/bin/hyperglass-bird << 'EOS'
#!/bin/bash
# Script to proxy hyperglass commands to BIRD socket

BIRD_SOCKET="/var/run/bird.ctl"

# Get command from stdin
read -r command

# Pass to BIRD socket
echo "$command" | socat - UNIX-CONNECT:$BIRD_SOCKET
EOS

  chmod +x /usr/local/bin/hyperglass-bird
fi

# Create systemd service for hyperglass
cat > /etc/systemd/system/hyperglass.service << 'EOS'
[Unit]
Description=hyperglass
Documentation=https://hyperglass.dev
After=network.target redis.service
Requires=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/hyperglass-venv
ExecStart=/opt/hyperglass-venv/bin/hyperglass start
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure
RestartSec=30s
Environment="HYPERGLASS_CONFIG_PATH=/etc/hyperglass/hyperglass.yaml"

[Install]
WantedBy=multi-user.target
EOS

# Update the Nginx configuration
cat > /etc/nginx/conf.d/hyperglass.conf << 'EOC'
server {
    listen 80;
    listen [::]:80;
    server_name lg.infinitum-nihil.com;
    
    # Redirect HTTP to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name lg.infinitum-nihil.com;
    
    ssl_certificate /etc/letsencrypt/live/lg.infinitum-nihil.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/lg.infinitum-nihil.com/privkey.pem;
    
    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    
    # Proxy to hyperglass
    location / {
        proxy_pass http://localhost:8001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOC

# Enable and start the systemd service
systemctl daemon-reload
systemctl enable hyperglass.service
systemctl start hyperglass.service

# Check the status
echo "Hyperglass service status:"
systemctl status hyperglass.service | head -15

# Restart Nginx
systemctl restart nginx

echo "Setup complete. Hyperglass should be available at https://lg.infinitum-nihil.com in a few moments."
echo "If it doesn't work immediately, check the service status with: systemctl status hyperglass"
EOF

echo "Hyperglass build script has been executed on the LAX server."
echo "It may take a few minutes for the application to fully start."
echo "Visit https://lg.infinitum-nihil.com to access the looking glass."