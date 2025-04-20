#!/bin/bash

# Load environment variables
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo "Loaded environment variables from $ENV_FILE"
else
    echo "Error: Environment file not found: $ENV_FILE"
    exit 1
fi

# Set script directory
SCRIPT_DIR="$(dirname "$0")"

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"

# Get LAX IP
PRIMARY_IP=$(cat "$HOME/birdbgp/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

echo -e "${BOLD}Starting deployment for LAX server${RESET}"
echo "============================================="
echo -e "${GREEN}LAX Server IP:${RESET} $PRIMARY_IP"
echo -e "${GREEN}Domain:${RESET} ${DOMAIN}"
echo "============================================="

deploy_to_lax() {
  local server_ip=$PRIMARY_IP
  
  # Create a temporary .env file for the server with only the needed variables
  cat > /tmp/server_env << EOF
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-"ssl@$DOMAIN"}
EOF

  # Create the deployment script
  cat > /tmp/lax_setup.sh << 'EOFMARKER'
#!/bin/bash
set -e

# Load environment variables
if [ -f "/tmp/server_env" ]; then
  source "/tmp/server_env"
  echo "Loaded environment variables from server_env"
else
  echo "Warning: No environment file found, using defaults"
  DOMAIN="infinitum-nihil.com"
  LETSENCRYPT_EMAIL="ssl@infinitum-nihil.com"
fi

# Configuration variables
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"

# Save credentials

# Set noninteractive mode to avoid prompts
export DEBIAN_FRONTEND=noninteractive

echo "[1] Updating system packages..."
apt update && DEBIAN_FRONTEND=noninteractive apt upgrade -y

echo "[2] Installing prerequisites..."
# Pre-configure iptables-persistent to automatically accept saving rules
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

# Check for any pending unattended upgrades and wait for them to complete
if pgrep unattended-upgrade > /dev/null; then
  echo "Waiting for unattended-upgrade to complete..."
  while pgrep unattended-upgrade > /dev/null; do
    sleep 5
  done
  echo "Unattended-upgrade completed"
fi

# Clear any apt locks that might be present
if [ -f /var/lib/apt/lists/lock ]; then
  echo "Clearing apt locks..."
  lsof /var/lib/apt/lists/lock || true
  lsof /var/lib/dpkg/lock-frontend || true
  lsof /var/lib/dpkg/lock || true
  # Only force-remove locks if they're stale (no process is using them)
  if ! lsof /var/lib/apt/lists/lock >/dev/null 2>&1; then
    rm -f /var/lib/apt/lists/lock
  fi
  if ! lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/lock-frontend
  fi
  if ! lsof /var/lib/dpkg/lock >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/lock
  fi
fi

# Fix any interrupted dpkg
dpkg --configure -a || true

# Install required packages

echo "[3] Setting up Docker..."
if ! command -v docker &> /dev/null; then
  sh get-docker.sh
  systemctl enable docker
  systemctl start docker
fi

echo "[4] Installing Docker Compose..."
if ! command -v docker compose &> /dev/null; then
  mkdir -p ~/.docker/cli-plugins/
  chmod +x ~/.docker/cli-plugins/docker-compose
  ln -sf ~/.docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
fi

echo "[5] Setting up anycast IP addresses..."
# Get main interface name
MAIN_INTERFACE=$(ip -br l | grep -v -E '(lo|veth|docker|dummy)' | awk '{print $1}')

# Create dummy interface if not exists
if ! ip link show dummy0 &>/dev/null; then
  echo "Creating dummy0 interface"
  modprobe dummy
  ip link add dummy0 type dummy
  ip link set dummy0 up
  echo "dummy" > /etc/modules-load.d/dummy.conf
fi

# Add anycast IPs to dummy interface
ip addr add $ANYCAST_IPV4/32 dev dummy0 2>/dev/null || echo "IPv4 anycast IP already exists"
ip -6 addr add $ANYCAST_IPV6/128 dev dummy0 2>/dev/null || echo "IPv6 anycast IP already exists"

# Create netplan directory if it doesn't exist
mkdir -p /etc/netplan

# Create temporary netplan file first
cat > /tmp/60-anycast.yaml << NETPLAN
network:
  version: 2
  ethernets:
    dummy0:
      match:
        name: dummy0
      addresses:
        - $ANYCAST_IPV4/32
        - $ANYCAST_IPV6/128
NETPLAN

# Copy with correct permissions to the final location
install -m 0600 -o root -g root /tmp/60-anycast.yaml /etc/netplan/60-anycast.yaml

# Apply network config
netplan apply || echo "netplan apply had non-zero exit code"

# Setup UFW if installed
if command -v ufw &>/dev/null; then
  ufw reload
fi

# Setup iptables rules
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Save iptables rules
netfilter-persistent save


# Create acme.json with correct permissions

# Generate secure password for admin access
HASHED_PASSWORD=$(htpasswd -nb admin "$ADMIN_PASSWORD" | sed -e s/\\$/\\$\\$/g)

  middlewares:
      redirectScheme:
        permanent: true
    admin-auth:
      basicAuth:
        users:
          - "$HASHED_PASSWORD"

tls:
  options:
    default:
      minVersion: VersionTLS12
      sniStrict: true
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
DYNAMIC

log:
  level: INFO

accessLog:
  filePath: "/logs/access.log"

api:
  insecure: false

entryPoints:
  web:
    address: ":80"
      redirections:
        entryPoint:
          to: websecure
  
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy
  
  file:
    directory: "/config"
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "$LETSENCRYPT_EMAIL"
      storage: "/data/acme.json"
        entryPoint: web
STATIC

services:
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    ports:
      - "${ANYCAST_IPV4}:80:80"
      - "${ANYCAST_IPV4}:443:443"
      - "[${ANYCAST_IPV6}]:80:80"
      - "[${ANYCAST_IPV6}]:443:443"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command:
    labels:

networks:
  proxy:
    name: proxy
    external: false

# Create required directories
mkdir -p $CONFIG_DIR

# Clean up any existing installation
rm -rf $DEST_DIR
mkdir -p $DEST_DIR
cd $DEST_DIR


# Create the configuration files

#!/bin/bash

BIRD_SOCKET="/var/run/bird/bird.ctl"

# Get command from stdin 
read -r command

# Pass to BIRD socket
echo "$command" | socat - UNIX-CONNECT:$BIRD_SOCKET
BIRDSCRIPT


cd $CONFIG_DIR

---
  listen_address: 0.0.0.0
  listen_port: 8001
  secret_key: $(openssl rand -hex 32)
  developer_mode: false
  debug: false
  log_level: info
  primary_asn: 27218

ui:
  text:
    title: "BGP Looking Glass"
    subtitle: "Infinitum Nihil BGP Anycast"
    info:
      pre_heading: "Network Information"
      heading: "Infinitum Nihil BGP Anycast"
    no_results: "No results found"
  colors:
    button: "#0098FF"
    title: "#0098FF"
    subtitle: "#00CC88"

queries:
  bgp_route:
    enable: true
    ipv4_limit: 24
    ipv6_limit: 64
  bgp_aspath:
    enable: true
  bgp_community:
    enable: true
  ping:
    enable: true
  traceroute:
    enable: true
CONFIG

# Create devices.yaml
# Get server info
HOSTNAME=$(hostname)
REGION=$(hostname | cut -d'-' -f1)
MAIN_IP=$(hostname -I | awk '{print $1}')

cat > $CONFIG_DIR/devices.yaml << DEVICES
---
# Bird2 Router Configuration
${REGION}-bgp:
  address: localhost
  asn: 27218
  credential:
    password: null
    username: null
  location: "$REGION"
  network: "Infinitum Nihil BGP"
  port: 179
  proxy: false
  type: bird2
  commands:
    bgp_route:
    bgp_community:
    bgp_aspath:
DEVICES

# Make sure config directory has correct permissions
chown -R root:root $CONFIG_DIR
chmod -R 755 $CONFIG_DIR

[Unit]
After=network.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
SERVICE

cat > $DEST_DIR/docker-compose.yml << DOCKER
services:
    restart: unless-stopped
    networks:
      - proxy
    ports:
      - "8001:8001"
    volumes:
    labels:
    environment:

networks:
  proxy:
    name: proxy
    external: false
DOCKER

docker compose down
docker compose pull
docker compose up -d

cd $DEST_DIR

# First try with docker-compose
docker compose down
docker compose pull
docker compose up -d

# If Docker doesn't work, try the systemd service
  echo "Docker method failed, trying systemd service..."
  systemctl daemon-reload
fi

echo "[9] Verifying installations..."
  # Write success flag
else
fi

else
  # Check if running as a service
  else
    echo "Let's try using the official image directly:"
    
    cd $DEST_DIR
    docker compose down
    
    # Try with the official image from GitHub Container Registry
    cat > docker-compose.yml << DIRECT_DOCKER
services:
    restart: unless-stopped
    networks:
      - proxy
    volumes:
    labels:
    environment:

networks:
  proxy:
    name: proxy
    external: false
DIRECT_DOCKER
    
    # Try one more time with GitHub authentication
    echo "Trying to authenticate with GitHub Container Registry..."
    docker compose pull
    docker compose up -d
    
    else
      echo "Check logs below:"
      docker compose logs
    fi
  fi
fi

echo "Testing BIRD socket proxy:"
  echo "✅ BIRD socket proxy is working"
else
  echo "❌ BIRD socket proxy failed"
fi

echo "IP Configuration:"
ip addr show dummy0

echo "Setup completed at $(date)"
EOFMARKER

  # Make the script executable
  chmod +x /tmp/lax_setup.sh
  
  # Copy the files to the server
  echo "Copying files to $server_ip..."
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/lax_setup.sh "root@$server_ip:/tmp/lax_setup.sh"
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/server_env "root@$server_ip:/tmp/server_env"
  
  # Execute the script remotely
  echo "Executing installation script on $server_ip..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@$server_ip" "bash /tmp/lax_setup.sh"
  
  # Check the installation status
  echo "Checking installation status..."
  sleep 5  # Give containers time to start
  
  
  
  else
  fi
  
  else
    # Try to diagnose the issue
    echo "Checking status and logs:"
  fi
  
  # Get domain and password information
  DOMAIN=${DOMAIN:-"infinitum-nihil.com"}
  
    echo ""
    echo ""
    echo "  - Username: admin"
    echo "  - Password: $ADMIN_PASSWORD"
  else
    echo -e "${RED}✗ Deployment had issues. Please check the server manually.${RESET}"
  fi
}

# Run the deployment
deploy_to_lax

echo -e "${GREEN}Deployment process completed.${RESET}"