#\!/bin/bash

# Deploy a basic bird2-looking-glass
# Created: 2025-05-23

SERVER_IP="149.248.2.74"
SERVER_NAME="LAX"

echo "Installing bird2-looking-glass on $SERVER_NAME..."

# Install node.js for the looking glass
ssh root@$SERVER_IP "
curl -fsSL https://deb.nodesource.com/setup_18.x  < /dev/null |  bash -
apt-get install -y nodejs

# Install the looking glass
cd /root
git clone https://github.com/sile/bird2-looking-glass.git
cd bird2-looking-glass
npm install

# Create a configuration file
cat > config.json << 'EOFCONFIG'
{
  \"server\": {
    \"port\": 80,
    \"host\": \"0.0.0.0\"
  },
  \"site\": {
    \"title\": \"AS27218 Infinitum Nihil Looking Glass\",
    \"asn\": 27218,
    \"description\": \"This looking glass provides real-time BGP routing information for the Infinitum Nihil network.\",
    \"logo\": \"\"
  },
  \"bird\": {
    \"ipv4\": {
      \"socket\": \"/var/run/bird/bird.ctl\"
    },
    \"ipv6\": {
      \"socket\": \"/var/run/bird/bird6.ctl\"
    }
  }
}
EOFCONFIG

# Create a service file
cat > /etc/systemd/system/bird2-lg.service << 'EOFSERVICE'
[Unit]
Description=Bird2 Looking Glass
After=network.target bird.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/bird2-looking-glass
ExecStart=/usr/bin/node src/server.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSERVICE

# Enable and start the service
systemctl daemon-reload
systemctl enable bird2-lg
systemctl start bird2-lg

# Allow web access
ufw allow 80/tcp comment 'Allow Looking Glass HTTP'
"

echo "Checking bird2-looking-glass service status..."
ssh root@$SERVER_IP "systemctl status bird2-lg"

echo "Bird2 Looking Glass should now be accessible at http://$SERVER_IP"
