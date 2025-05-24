#\!/bin/bash

# Script to deploy Hyperglass on LAX server
# Created: 2025-05-23

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SERVER_IP="149.248.2.74"
SERVER_NAME="LAX"

# Create directories on server
echo -e "${YELLOW}Creating directories on $SERVER_NAME...${NC}"
ssh root@$SERVER_IP "mkdir -p /etc/hyperglass/data /etc/traefik/dynamic /var/www/acme /usr/local/bin"

# Copy configuration files
echo -e "${YELLOW}Copying configuration files to $SERVER_NAME...${NC}"
scp lax_hyperglass.yaml root@$SERVER_IP:/etc/hyperglass/hyperglass.yaml
scp lax_traefik.yaml root@$SERVER_IP:/etc/traefik/traefik.yaml
scp lax_dashboard.yaml root@$SERVER_IP:/etc/traefik/dynamic/dashboard.yaml
scp lax_docker_compose.yml root@$SERVER_IP:/root/docker-compose.yml
scp hyperglass-bird root@$SERVER_IP:/usr/local/bin/

# Ensure script is executable
echo -e "${YELLOW}Setting permissions on hyperglass-bird script...${NC}"
ssh root@$SERVER_IP "chmod +x /usr/local/bin/hyperglass-bird"

# Set up anycast IP for the looking glass
echo -e "${YELLOW}Setting up anycast IP (192.30.120.10) on $SERVER_NAME...${NC}"
ssh root@$SERVER_IP "
if \! ip link show dummy0 > /dev/null 2>&1; then
  echo 'Creating dummy interface...'
  modprobe dummy
  ip link add dummy0 type dummy
  ip link set dummy0 up
fi

# Add anycast IPv4 address if not already assigned
if \! ip addr show dev dummy0  < /dev/null |  grep -q '192.30.120.10'; then
  ip addr add 192.30.120.10/32 dev dummy0
  echo 'Added anycast IPv4 address 192.30.120.10 to dummy0'
fi

# Add anycast IPv6 address if not already assigned
if \! ip addr show dev dummy0 | grep -q '2620:71:4000::c01e:780a'; then
  ip addr add 2620:71:4000::c01e:780a/128 dev dummy0
  echo 'Added anycast IPv6 address 2620:71:4000::c01e:780a to dummy0'
fi

# Make interface persist across reboots
cat > /etc/systemd/network/10-dummy0.netdev << 'NETDEV'
[NetDev]
Name=dummy0
Kind=dummy
NETDEV

cat > /etc/systemd/network/20-dummy0.network << 'NETWORK'
[Match]
Name=dummy0

[Network]
Address=192.30.120.10/32
Address=2620:71:4000::c01e:780a/128
NETWORK

# Reload systemd-networkd if it's running
systemctl is-active --quiet systemd-networkd && systemctl restart systemd-networkd

# Allow incoming traffic to looking glass ports
ufw allow 80/tcp comment 'Allow HTTP for Hyperglass'
ufw allow 443/tcp comment 'Allow HTTPS for Hyperglass'
ufw allow 8080/tcp comment 'Allow internal Hyperglass API'
"

# Check if Docker is installed, if not install it
echo -e "${YELLOW}Checking Docker installation on $SERVER_NAME...${NC}"
ssh root@$SERVER_IP "
if \! command -v docker &> /dev/null; then
    echo 'Installing Docker...'
    apt-get update
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable' | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo 'Docker installed successfully'
else
    echo 'Docker is already installed'
fi

# Install Docker Compose if not already installed
if \! command -v docker compose &> /dev/null; then
    echo 'Installing Docker Compose...'
    apt-get update
    apt-get install -y docker-compose-plugin
    echo 'Docker Compose installed successfully'
else
    echo 'Docker Compose is already installed'
fi
"

# Start the Docker containers
echo -e "${YELLOW}Starting Docker containers on $SERVER_NAME...${NC}"
ssh root@$SERVER_IP "cd /root && docker compose up -d"

# Check if containers are running
echo -e "${YELLOW}Checking container status on $SERVER_NAME...${NC}"
ssh root@$SERVER_IP "docker ps"

echo -e "${GREEN}Deployment to $SERVER_NAME completed\!${NC}"
echo -e "${YELLOW}You can now access the looking glass at https://lg.infinitum-nihil.com${NC}"
echo -e "${YELLOW}Note: DNS and certificate propagation may take a few minutes.${NC}"
