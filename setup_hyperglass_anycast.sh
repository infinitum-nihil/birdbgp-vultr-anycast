#!/bin/bash
# setup_hyperglass_anycast.sh - Deploys Hyperglass on anycast IP

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed
PRIMARY_SERVER="lax"
PRIMARY_IP="149.248.2.74"
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::10"
DOMAIN="lg.infinitum-nihil.com"  # Replace with your actual domain

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="hyperglass_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to ensure anycast IP is configured
ensure_anycast_ip() {
  echo -e "${BLUE}Ensuring anycast IP is configured on $PRIMARY_SERVER ($PRIMARY_IP)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$PRIMARY_IP" "
    # Ensure loopback has anycast IP
    if ! ip addr show lo | grep -q '$ANYCAST_IPV4'; then
      ip addr add $ANYCAST_IPV4/32 dev lo
      echo 'Added IPv4 anycast IP to loopback'
    fi
    
    if ! ip addr show lo | grep -q '$ANYCAST_IPV6'; then
      ip addr add $ANYCAST_IPV6/128 dev lo
      echo 'Added IPv6 anycast IP to loopback'
    fi
    
    # Make changes persistent
    if ! grep -q '$ANYCAST_IPV4' /etc/network/interfaces; then
      cat >> /etc/network/interfaces << EOL

# Anycast IPs
post-up ip addr add $ANYCAST_IPV4/32 dev lo
post-up ip addr add $ANYCAST_IPV6/128 dev lo
EOL
      echo 'Made anycast IPs persistent'
    fi
    
    # Ensure dummy interface has anycast IP (for BGP announcements)
    if ! ip link show dummy0 &>/dev/null; then
      modprobe dummy
      ip link add dummy0 type dummy
      ip link set dummy0 up
      echo 'Created dummy0 interface'
    fi
    
    if ! ip addr show dummy0 | grep -q '$ANYCAST_IPV4'; then
      ip addr add $ANYCAST_IPV4/32 dev dummy0
      echo 'Added IPv4 anycast IP to dummy0'
    fi
    
    if ! ip addr show dummy0 | grep -q '$ANYCAST_IPV6'; then
      ip addr add $ANYCAST_IPV6/128 dev dummy0
      echo 'Added IPv6 anycast IP to dummy0'
    fi
    
    # Make dummy module persistent
    if ! grep -q 'dummy' /etc/modules; then
      echo 'dummy' >> /etc/modules
    fi
    
    # Ensure IP forwarding is enabled
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    
    # Make sysctl changes persistent
    if ! grep -q 'net.ipv4.ip_forward' /etc/sysctl.conf; then
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
      echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
    fi
  "
}

# Function to ensure anycast routes are properly announced
ensure_anycast_routes() {
  echo -e "${BLUE}Ensuring anycast routes are properly announced...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$PRIMARY_IP" "
    # Check BIRD configuration
    if ! grep -q '$ANYCAST_IPV4' /etc/bird/conf.d/static_anycast.conf 2>/dev/null; then
      # Create static routes configuration
      cat > /etc/bird/conf.d/static_anycast.conf << 'EOL'
# Anycast static routes
# Created by setup_hyperglass_anycast.sh

protocol static static_anycast_v4 {
  ipv4 {
    export all;
  };
  
  # IPv4 anycast routes
  route $ANYCAST_IPV4/32 via \"lo\";
  route 192.30.120.0/23 blackhole;
}

protocol static static_anycast_v6 {
  ipv6 {
    export all;
  };
  
  # IPv6 anycast routes
  route $ANYCAST_IPV6/128 via \"lo\";
  route 2620:71:4000::/48 blackhole;
}
EOL

      # Apply configuration
      birdc configure
      echo 'Added anycast routes to BIRD configuration'
    fi
  "
}

# Function to deploy Hyperglass
deploy_hyperglass() {
  echo -e "${BLUE}Deploying Hyperglass on $PRIMARY_SERVER ($PRIMARY_IP)...${NC}"
  
  # Copy the most recent hyperglass setup script to the server
  scp -i "$SSH_KEY_PATH" /home/normtodd/birdbgp/hyperglass_backup/setup_looking_glass.sh "root@$PRIMARY_IP:/root/"
  
  # Execute the script with modified settings
  ssh -i "$SSH_KEY_PATH" "root@$PRIMARY_IP" "
    # Make sure Docker is installed
    if ! command -v docker &> /dev/null; then
      apt-get update
      apt-get install -y docker.io docker-compose
    fi
    
    # Set environment variables for the script
    export HYPERGLASS_LISTEN_ADDR=$ANYCAST_IPV4
    export HYPERGLASS_DOMAIN=$DOMAIN
    
    # Run the setup script
    cd /root
    chmod +x setup_looking_glass.sh
    ./setup_looking_glass.sh
  "
}

# Function to configure Nginx for anycast IP
configure_nginx() {
  echo -e "${BLUE}Configuring Nginx to listen on anycast IP...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$PRIMARY_IP" "
    # Create Nginx configuration
    cat > /etc/nginx/sites-available/hyperglass << 'EOL'
server {
    listen $ANYCAST_IPV4:80;
    listen [::]:80;
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:8001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

    # Enable the site
    ln -sf /etc/nginx/sites-available/hyperglass /etc/nginx/sites-enabled/
    
    # Test and reload Nginx
    nginx -t && systemctl reload nginx
  "
}

# Function to verify setup
verify_setup() {
  echo -e "${BLUE}Verifying Hyperglass setup...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$PRIMARY_IP" "
    # Check if Hyperglass is running
    if docker ps | grep -q hyperglass; then
      echo 'Hyperglass container is running'
    else
      echo 'Hyperglass container is not running!'
      docker ps -a | grep hyperglass
    fi
    
    # Check Nginx status
    systemctl status nginx
    
    # Check if anycast IP is accessible
    curl -s -I http://$ANYCAST_IPV4/ || echo 'Cannot access Hyperglass via anycast IP'
    
    # Check anycast route propagation
    birdc show route for $ANYCAST_IPV4/32
  "
}

# Main function
main() {
  echo -e "${BLUE}Starting Hyperglass deployment on anycast IP...${NC}"
  
  # Ensure anycast IP is configured
  ensure_anycast_ip
  
  # Ensure anycast routes are properly announced
  ensure_anycast_routes
  
  # Deploy Hyperglass
  deploy_hyperglass
  
  # Configure Nginx
  configure_nginx
  
  # Verify setup
  verify_setup
  
  echo -e "${GREEN}Hyperglass deployment completed!${NC}"
  echo -e "${YELLOW}You can access Hyperglass at:${NC}"
  echo -e "  - http://$ANYCAST_IPV4/"
  echo -e "  - http://$DOMAIN/ (once DNS is configured)"
}

# Run the main function
main