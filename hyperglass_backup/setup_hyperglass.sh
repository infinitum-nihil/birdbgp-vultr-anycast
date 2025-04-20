#!/bin/bash
# Script to properly set up hyperglass with BIRD
# Following the official documentation at https://hyperglass.dev

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Setting up hyperglass with BIRD on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Stop existing containers
echo "Stopping existing containers..."
docker stop hyperglass redis 2>/dev/null || true

# Make sure we have Git and Docker Compose
apt-get update && apt-get install -y git

# Prepare directories
mkdir -p /etc/hyperglass

# Check if BIRD config already exists
if [ ! -f "/etc/hyperglass/hyperglass.yaml" ]; then
  echo "Creating hyperglass configuration..."
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
  host: redis
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
else
  echo "Hyperglass configuration already exists"
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

# Make sure socat is installed
apt-get install -y socat

# Make the BIRD socket accessible
if [ -S /var/run/bird.ctl ]; then
  chmod 666 /var/run/bird.ctl
  echo "BIRD socket permissions updated"
else
  echo "Warning: BIRD socket not found. Make sure BIRD is running."
fi

# Clone the hyperglass repository
cd /opt
if [ ! -d "/opt/hyperglass" ]; then
  echo "Cloning hyperglass repository..."
  git clone https://github.com/thatmattlove/hyperglass.git --depth=1
else
  echo "Hyperglass repository already exists"
  cd /opt/hyperglass
  git pull
fi

# Create the docker-compose file
cd /opt/hyperglass
cat > docker-compose.yml << 'EOC'
services:
  ui:
    image: thatmattlove/hyperglass:latest
    container_name: hyperglass
    restart: unless-stopped
    ports:
      - "8001:8001"
    volumes:
      - /etc/hyperglass:/etc/hyperglass
      - /var/run/bird.ctl:/var/run/bird.ctl
    environment:
      - HYPERGLASS_CONFIG_PATH=/etc/hyperglass/hyperglass.yaml
    depends_on:
      - redis

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes

volumes:
  redis_data:
EOC

# Create systemd service file
cp /opt/hyperglass/.samples/hyperglass-docker.service /etc/hyperglass/hyperglass.service 2>/dev/null || echo "Could not copy sample service file"
ln -sf /etc/hyperglass/hyperglass.service /etc/systemd/system/hyperglass.service 2>/dev/null

# Create a systemd service file manually if sample is not available
if [ ! -f "/etc/systemd/system/hyperglass.service" ]; then
  cat > /etc/systemd/system/hyperglass.service << 'EOS'
[Unit]
Description=hyperglass
Documentation=https://hyperglass.dev
After=network.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
Group=root
TimeoutStartSec=0
Restart=on-failure
RestartSec=30s
ExecStartPre=-/usr/bin/docker stop hyperglass redis
ExecStartPre=-/usr/bin/docker rm hyperglass redis
ExecStart=/usr/bin/docker compose -f /opt/hyperglass/docker-compose.yml up
ExecStop=/usr/bin/docker compose -f /opt/hyperglass/docker-compose.yml down
WorkingDirectory=/opt/hyperglass

[Install]
WantedBy=multi-user.target
EOS
fi

# Create Nginx configuration for hyperglass
mkdir -p /etc/nginx/conf.d
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
systemctl restart hyperglass.service

# Check the status
echo "Hyperglass service status:"
systemctl status hyperglass.service | head -15

# Install Nginx if it's not already installed
if ! command -v nginx >/dev/null; then
  apt-get install -y nginx
fi

# Test Nginx configuration
nginx -t

# Restart Nginx
systemctl restart nginx

echo "Setup complete. Hyperglass should be available at https://lg.infinitum-nihil.com"
EOF

echo "Hyperglass setup script has been executed on the LAX server."
echo "It may take a few minutes for the application to fully start."
echo "Visit https://lg.infinitum-nihil.com to access the looking glass."