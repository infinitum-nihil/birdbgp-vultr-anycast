#!/bin/bash
# Script to properly fix Redis connection in Hyperglass

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create Redis connection fix script
cat > /tmp/fix_redis_connection.sh << 'EOF'
#!/bin/bash
set -e

echo "Fixing Redis connection for Hyperglass..."

# Create a custom Hyperglass configuration directory
mkdir -p /etc/hyperglass

# Create hyperglass.yaml config file with Redis properly configured
cat > /etc/hyperglass/hyperglass.yaml << 'CONFIG'
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
CONFIG

# Create BIRD socket access script for hyperglass
cat > /usr/local/bin/hyperglass-bird << 'BIRDSCRIPT'
#!/bin/bash
# Script to proxy hyperglass commands to BIRD socket

BIRD_SOCKET="/var/run/bird.ctl"

# Get command from stdin
read -r command

# Pass to BIRD socket
echo "$command" | socat - UNIX-CONNECT:$BIRD_SOCKET
BIRDSCRIPT

# Make script executable
chmod +x /usr/local/bin/hyperglass-bird

# Ensure BIRD socket permissions allow access from Docker containers
if [ -S /var/run/bird.ctl ]; then
  chmod 666 /var/run/bird.ctl
  ls -la /var/run/bird.ctl
else
  echo "BIRD socket not found at /var/run/bird.ctl - checking alternative locations"
  find /var/run -name "*.ctl" 2>/dev/null || echo "No BIRD sockets found in /var/run"
fi

# Create Hyperglass environment variables file
cat > /etc/hyperglass/hyperglass.env << 'ENVFILE'
HYPERGLASS_APP_PATH=/etc/hyperglass
HYPERGLASS_SECRET_KEY=vOVH6sdmpNWjRRIqCc7rdxs01lwHzfr3
HYPERGLASS_DEBUG=false
HYPERGLASS_DEV_MODE=false
HYPERGLASS_HOST=0.0.0.0
HYPERGLASS_PORT=8001
HYPERGLASS_REDIS_HOST=redis
HYPERGLASS_REDIS_PORT=6379
HYPERGLASS_REDIS_DB=0
ENVFILE

# Update Docker Compose file to use a simple Python container with Hyperglass installed
cat > /opt/hyperglass/docker-compose.yml << 'DOCKER'
services:
  hyperglass:
    image: python:3.9-slim
    container_name: hyperglass
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8001:8001"
    volumes:
      - /etc/hyperglass:/etc/hyperglass:ro
      - /var/run:/var/run:ro
      - /usr/local/bin/hyperglass-bird:/usr/local/bin/hyperglass-bird:ro
    environment:
      - HYPERGLASS_APP_PATH=/etc/hyperglass
      - HYPERGLASS_SECRET_KEY=vOVH6sdmpNWjRRIqCc7rdxs01lwHzfr3
      - HYPERGLASS_DEBUG=false
      - HYPERGLASS_DEV_MODE=false
      - HYPERGLASS_HOST=0.0.0.0
      - HYPERGLASS_PORT=8001
      - HYPERGLASS_REDIS_HOST=redis
      - HYPERGLASS_REDIS_PORT=6379
      - HYPERGLASS_REDIS_DB=0
    depends_on:
      - redis
    command: >
      bash -c "
        apt-get update && 
        apt-get install -y socat curl iputils-ping traceroute git &&
        pip install hyperglass redis &&
        echo '#!/bin/bash' > /usr/local/bin/entrypoint.sh &&
        echo 'echo \"Testing BIRD socket...\"' >> /usr/local/bin/entrypoint.sh &&
        echo 'echo \"show status\" | socat - UNIX-CONNECT:/var/run/bird.ctl || (echo \"Bird socket not accessible\"; exit 1)' >> /usr/local/bin/entrypoint.sh &&
        echo 'echo \"Waiting for Redis...\"' >> /usr/local/bin/entrypoint.sh &&
        echo 'until nc -z redis 6379; do sleep 1; done;' >> /usr/local/bin/entrypoint.sh &&
        echo 'echo \"Starting Hyperglass...\"' >> /usr/local/bin/entrypoint.sh &&
        echo 'cd /etc/hyperglass && python -m hyperglass' >> /usr/local/bin/entrypoint.sh &&
        chmod +x /usr/local/bin/entrypoint.sh &&
        /usr/local/bin/entrypoint.sh
      "
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hyperglass-sub.rule=Host(`lg.infinitum-nihil.com`)"
      - "traefik.http.routers.hyperglass-sub.entrypoints=websecure"
      - "traefik.http.routers.hyperglass-sub.tls.certresolver=letsencrypt"
      - "traefik.http.services.hyperglass.loadbalancer.server.port=8001"

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

# Add a simple helper script to check the status and logs
cat > /opt/hyperglass/check_status.sh << 'CHECKSCRIPT'
#!/bin/bash
echo "Checking Redis status..."
docker exec redis redis-cli ping

echo "Checking BIRD socket permissions..."
ls -la /var/run/bird.ctl

echo "Checking container logs..."
echo "--- Hyperglass Logs ---"
docker logs hyperglass

echo "--- Redis Logs ---"
docker logs redis
CHECKSCRIPT

chmod +x /opt/hyperglass/check_status.sh

# Restart the containers
cd /opt/hyperglass
docker compose down
docker compose up -d

# Wait for containers to start
echo "Waiting for containers to start..."
sleep 10

# Run the status check
echo "Running status check..."
/opt/hyperglass/check_status.sh

echo "Redis connection fix completed"
EOF

chmod +x /tmp/fix_redis_connection.sh

# Upload and execute on LAX server
echo "Uploading Redis connection fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_redis_connection.sh root@$LAX_IP:/tmp/fix_redis_connection.sh

echo "Executing Redis connection fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_redis_connection.sh"

echo "Redis connection fixed with a proper Hyperglass implementation"