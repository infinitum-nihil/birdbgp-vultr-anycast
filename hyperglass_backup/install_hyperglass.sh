#!/bin/bash
# Script to install Hyperglass with Python 3.13.3
# Run this script after Python 3.13.3 has been successfully installed

set -e  # Exit on error

# Target server
SERVER_IP="149.248.2.74"

echo "Preparing to install Hyperglass on $SERVER_IP with Python 3.13.3..."

# Create the installation script
cat > /tmp/hyperglass_installer.sh << 'EOF'
#!/bin/bash
set -e

echo "Starting Hyperglass installation..."

# Verify Python version
PYTHON_VERSION=$(python3 --version)
echo "Python version: $PYTHON_VERSION"

# Check if Python version is at least 3.11
PYTHON_VERSION_OK=$(python3 -c "import sys; print(sys.version_info >= (3, 11))")
if [ "$PYTHON_VERSION_OK" != "True" ]; then
  echo "Error: Hyperglass requires Python 3.11 or higher. Please complete the Python upgrade first."
  exit 1
fi

# 1. Install prerequisites
echo "Installing prerequisites..."
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  wget curl llvm libncurses5-dev libncursesw5-dev xz-utils tk-dev libffi-dev \
  liblzma-dev python3-openssl git socat redis-server nodejs npm

# Update npm and install pnpm
echo "Installing PNPM..."
npm install -g npm@latest
npm install -g pnpm

# 2. Set up Python environment
echo "Setting up Python environment..."
mkdir -p /opt/hyperglass
python3 -m venv /opt/hyperglass-venv
source /opt/hyperglass-venv/bin/activate

# 3. Clone Hyperglass repository
echo "Cloning Hyperglass repository..."
cd /opt
if [ -d "hyperglass" ]; then
  echo "Removing existing hyperglass directory..."
  rm -rf hyperglass
fi
git clone https://github.com/thatmattlove/hyperglass --depth=1

# 4. Install Hyperglass
echo "Installing Hyperglass..."
cd /opt/hyperglass
pip install --upgrade pip
pip install -e .

# 5. Configure Hyperglass
echo "Configuring Hyperglass..."
mkdir -p /etc/hyperglass

# Create configuration file
cat > /etc/hyperglass/hyperglass.yaml << 'EOC'
hyperglass:
  debug: false
  developer_mode: false
  listen_address: 0.0.0.0
  listen_port: 8001
  log_level: info
  docs: true
  external_link_mode: icon
  external_link_icon: external-link
  legacy_api: false
  private_asn: false
  cache_timeout: 600

redis:
  host: localhost
  port: 6379
  password: null
  database: 0
  timeout: 1.0
  use_sentinel: false
  sentinel_hosts: []
  sentinel_port: 26379
  sentinel_master: "mymaster"

general:
  primary_asn: 27218
  org_name: "Infinitum Nihil BGP Anycast"
  filter: false
  credit: true
  limit:
    ipv4: 24
    ipv6: 64
  google_analytics:
    enabled: false

web:
  title: "BGP Looking Glass"
  subtitle: "View BGP routing information"
  greeting: "Network visibility with BIRD 2.16.2"
  title_mode: separate
  favicon: null
  logo: null
  text:
    bgp_aspath: "AS Path"
    bgp_community: "BGP Community"
    bgp_route: "BGP Route"
    ping: "Ping"
    traceroute: "Traceroute"
  text_size: md
  theme:
    colors:
      primary: '#0098FF'
      secondary: '#00CC88'
      background: '#fff'
      black: '#000'
      white: '#fff'
      dark:
        100: '#e6e6e6'
        200: '#cccccc'
        300: '#b3b3b3'
        400: '#999999'
        500: '#808080'
        600: '#666666'
        700: '#4d4d4d'
        800: '#333333'
        900: '#1a1a1a'
    font:
      sans: 'Inter'
    radius: md

routers:
  - name: "bird-local"
    address: "localhost"
    network: "Local BGP"
    location: "LAX"
    asn: 27218
    port: 179
    credential:
      username: null
      password: null
    type: bird2
    ignore_version: true
    proxy: true
    proxy_command: /usr/local/bin/hyperglass-bird
    attrs:
      source4: "45.76.76.125"
      source6: "2607:f0d0:1204:2e::1"

commands:
  bgp_route:
    default: true
    ipv4:
      bird2: "show route for {target} all"
    ipv6:
      bird2: "show route for {target} all"
  bgp_community:
    default: true
    ipv4:
      bird2: "show route where community ~ [{target}] all"
    ipv6:
      bird2: "show route where community ~ [{target}] all"
  bgp_aspath:
    default: true
    ipv4:
      bird2: "show route where bgp_path ~ [{target}] all"
    ipv6:
      bird2: "show route where bgp_path ~ [{target}] all"
  ping:
    default: true
    ipv4:
      command: "ping -c 5 -w 5 {target}"
    ipv6: 
      command: "ping6 -c 5 -w 5 {target}"
  traceroute:
    default: true
    ipv4:
      command: "traceroute -w 1 -q 1 -n {target}"
    ipv6:
      command: "traceroute6 -w 1 -q 1 -n {target}"

messages:
  no_output: "Command completed, but returned no output."
  authentication:
    failed: "Authentication failed."
    timeout: "Authentication timed out."
  connection:
    timeout: "The connection timed out."
    refused: "The connection was refused."
    success: "The connection was successful, but something else went wrong."
EOC

# 6. Create BIRD proxy script
echo "Creating BIRD proxy script..."
cat > /usr/local/bin/hyperglass-bird << 'EOS'
#!/bin/bash
# Script to proxy hyperglass commands to BIRD socket

BIRD_SOCKET="/var/run/bird/bird.ctl"

# Find BIRD socket if not at the default location
if [ ! -S "$BIRD_SOCKET" ]; then
  FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
  if [ -n "$FOUND_SOCKET" ]; then
    BIRD_SOCKET="$FOUND_SOCKET"
  fi
fi

# Get command from stdin
read -r command

# Pass to BIRD socket using socat
echo "$command" | socat - UNIX-CONNECT:$BIRD_SOCKET
EOS

chmod +x /usr/local/bin/hyperglass-bird

# 7. Set BIRD socket permissions
echo "Setting BIRD socket permissions..."
BIRD_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
if [ -S "$BIRD_SOCKET" ]; then
  echo "Found BIRD socket at $BIRD_SOCKET"
  chmod 666 "$BIRD_SOCKET"
  sed -i "s|/var/run/bird/bird.ctl|$BIRD_SOCKET|g" /usr/local/bin/hyperglass-bird
else
  echo "Warning: BIRD socket not found. Ensure BIRD is running."
fi

# Test BIRD proxy script
echo "Testing BIRD proxy script..."
echo "show status" | /usr/local/bin/hyperglass-bird || echo "BIRD proxy test failed. Continuing anyway."

# 8. Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/hyperglass.service << 'EOS'
[Unit]
Description=hyperglass
Documentation=https://hyperglass.dev
After=network.target redis-server.service
Requires=network.target redis-server.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/hyperglass
ExecStart=/opt/hyperglass-venv/bin/hyperglass start
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure
RestartSec=30s
Environment="HYPERGLASS_CONFIG_PATH=/etc/hyperglass/hyperglass.yaml"

[Install]
WantedBy=multi-user.target
EOS

# 9. Start Redis server
echo "Starting Redis server..."
systemctl enable redis-server
systemctl restart redis-server

# 10. Update Nginx configuration
echo "Updating Nginx configuration..."
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

# 11. Enable and start Hyperglass service
echo "Starting Hyperglass service..."
systemctl daemon-reload
systemctl enable hyperglass.service

# Keep the static page available in case of initial startup issues
mkdir -p /var/www/hyperglass-backup
cp -r /var/www/looking-glass/* /var/www/hyperglass-backup/

# Start the service
echo "Starting Hyperglass service..."
systemctl start hyperglass.service

# 12. Verify service status
echo "Checking service status..."
systemctl status hyperglass.service --no-pager

# 13. Reload Nginx
echo "Reloading Nginx..."
nginx -t && systemctl reload nginx

echo "Installation complete! Hyperglass should be accessible at https://lg.infinitum-nihil.com"
echo "If there are any issues, the previous static page has been backed up to /var/www/hyperglass-backup/"
EOF

# Make the script executable
chmod +x /tmp/hyperglass_installer.sh

# Upload and execute the script on the remote server
echo "Copying installation script to $SERVER_IP..."
scp -o StrictHostKeyChecking=no /tmp/hyperglass_installer.sh root@$SERVER_IP:/tmp/

echo "Hyperglass installation script has been created and uploaded to the server."
echo "To install Hyperglass after Python 3.13.3 is installed, run:"
echo "  ssh root@$SERVER_IP 'bash /tmp/hyperglass_installer.sh'"