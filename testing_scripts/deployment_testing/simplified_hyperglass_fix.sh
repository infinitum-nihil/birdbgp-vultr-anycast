#\!/bin/bash

# Fix the Hyperglass configuration
# Created: 2025-05-23

SERVER_IP="149.248.2.74"

echo "Fixing Hyperglass configuration on LAX..."

# Create a minimal hyperglass.yaml config file
cat > minimal_hyperglass.yaml << 'EOFCONFIG'
# Minimal Hyperglass configuration
debug: false
hyperglass:
  listen_address: 0.0.0.0
  listen_port: 8080
  log_level: info

devices:
  - name: lax1
    display_name: "Los Angeles (LAX)"
    address: localhost
    credential:
      type: subprocess
      command: /usr/local/bin/hyperglass-bird
    platform: bird
    location:
      lat: 34.0522
      lon: -118.2437

redis_host: redis
redis_port: 6379
cache_timeout: 3600

asn: 27218
org_name: "Infinitum Nihil, LLC"
site_title: "27218 Infinitum Nihil LG"
site_description: "BGP Looking Glass for AS27218 Infinitum Nihil Network"
EOFCONFIG

# Create a simplified BIRD proxy script
cat > simple_hyperglass_bird << 'EOFSCRIPT'
#\!/bin/bash

# Simple proxy for Hyperglass to execute BIRD commands
# Created: 2025-05-23

# Commands allowed for security
ALLOWED_COMMANDS=("show protocol" "show protocols" "show route" "show route for" "show route where" "show symbols")

COMMAND="$*"
FIRST_WORD=$(echo $COMMAND  < /dev/null |  awk '{print $1}')
SECOND_WORD=$(echo $COMMAND | awk '{print $2}')

# Check if command is allowed
if [[ "$FIRST_WORD" == "show" ]]; then
  # Use appropriate socket for IPv4/IPv6
  if [[ "$*" == *"::"* ]]; then
    # IPv6 command
    birdc -s /var/run/bird/bird6.ctl "$@"
  else
    # IPv4 command
    birdc -s /var/run/bird/bird.ctl "$@"
  fi
else
  echo "Error: Command not allowed for security reasons"
  exit 1
fi
EOFSCRIPT

# Copy files to server
scp minimal_hyperglass.yaml root@$SERVER_IP:/etc/hyperglass/hyperglass.yaml
scp simple_hyperglass_bird root@$SERVER_IP:/usr/local/bin/hyperglass-bird

# Set permissions
ssh root@$SERVER_IP "chmod +x /usr/local/bin/hyperglass-bird && chown -R root:root /etc/hyperglass"

# Clean up existing containers and restart
ssh root@$SERVER_IP "docker stop hyperglass redis traefik || true"
ssh root@$SERVER_IP "docker rm hyperglass redis traefik || true"
ssh root@$SERVER_IP "docker network rm proxy root_lg_network || true"

# Start with a simple docker run command to test
ssh root@$SERVER_IP "docker network create hyperglass_network || true"
ssh root@$SERVER_IP "docker run -d --name redis --network hyperglass_network redis:7-alpine"
ssh root@$SERVER_IP "docker run -d --name hyperglass --network hyperglass_network -p 80:8080 \
  -e REDIS_HOST=redis -e REDIS_PORT=6379 \
  -v /etc/hyperglass/hyperglass.yaml:/app/hyperglass.yaml:ro \
  -v /usr/local/bin/hyperglass-bird:/usr/local/bin/hyperglass-bird:ro \
  -v /var/run/bird:/var/run/bird \
  ghcr.io/thatmattlove/hyperglass:latest"

echo "Checking container status..."
ssh root@$SERVER_IP "docker ps"
ssh root@$SERVER_IP "docker logs hyperglass | tail -20"

echo "Hyperglass should now be accessible at http://$SERVER_IP"
