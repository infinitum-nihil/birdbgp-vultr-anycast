#!/bin/bash
# Script to fix web access to lg.infinitum-nihil.com
# Created by Claude

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Fixing web access configuration on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Allow web traffic through the firewall
echo "Configuring firewall to allow web traffic..."
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8001/tcp

# Allow traffic on all interfaces, including dummy0 for anycast IP
ufw allow in on dummy0
ufw allow in on enp1s0

# Reload UFW
ufw reload

# Check UFW status
echo "Firewall status:"
ufw status

  
server {
    listen 80;
    listen [::]:80;
    server_name _;  # Catch all hostnames

    location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOC

  # Enable the site
  
elif command -v docker >/dev/null 2>&1; then
  
  
server {
    listen 80;
    listen [::]:80;
    server_name _;  # Catch all hostnames

    location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOC

    --network=host \
    --restart=unless-stopped \
else
  
server {
    listen 80;
    listen [::]:80;
    server_name _;  # Catch all hostnames

    location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOC

  # Enable the site
  
fi

# Verify port 80 is now listening
echo "Checking listening ports:"
netstat -tulpn | grep -E ':(80|443|8001)'

# Check if the anycast IP is properly attached to the dummy interface
echo "Checking anycast IP configuration:"
ip addr show dev dummy0 | grep 192.30.120.10

# Test local web access
echo "Testing local web access:"
EOF

echo "Web access configuration has been fixed on LAX server."
echo "You should now be able to access lg.infinitum-nihil.com in your browser."
echo "If you still have issues, make sure your DNS record points to 192.30.120.10."