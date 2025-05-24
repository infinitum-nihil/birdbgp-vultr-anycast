#!/bin/bash
# Script to check the status of Hyperglass deployment on all BGP speakers

# ANSI color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
CONFIG_FILE="/home/normtodd/birdbgp/config_files/config.json"
DOMAIN="infinitum-nihil.com"
SUBDOMAIN="lg"

# Get server information from config file
LAX_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-west".lax.ipv4.address' "$CONFIG_FILE")
EWR_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".ewr.ipv4.address' "$CONFIG_FILE")
MIA_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-east".mia.ipv4.address' "$CONFIG_FILE")
ORD_IPV4=$(jq -r '.cloud_providers.vultr.servers."us-central".ord.ipv4.address' "$CONFIG_FILE")

# Server list for iteration
SERVER_IPS=($LAX_IPV4 $EWR_IPV4 $MIA_IPV4 $ORD_IPV4)
SERVER_NAMES=("LAX" "EWR" "MIA" "ORD")

# Check for jq dependency
if ! command -v jq &> /dev/null; then
  echo -e "${YELLOW}jq is not installed. Installing...${NC}"
  apt-get update && apt-get install -y jq
fi

# Function to check Hyperglass status
check_hyperglass_status() {
  local server_ip=$1
  local server_name=$2
  
  echo -e "${BLUE}Checking Hyperglass status on $server_name server ($server_ip)...${NC}"
  
  # Create a temporary script to check the Hyperglass status
  cat > /tmp/check_hyperglass.sh << 'EOT'
#!/bin/bash

# Function to print section header
print_header() {
    echo -e "\n\033[1;36m==== $1 ====\033[0m"
}

# Check if Docker is installed
print_header "Docker Status"
if ! command -v docker &> /dev/null; then
  echo "❌ Docker is not installed"
  exit 1
else
  echo "✅ Docker is installed"
  docker --version
fi

# Check Docker service status
print_header "Docker Service Status"
systemctl status docker --no-pager | grep "Active:"

# Check Docker Compose status
print_header "Docker Compose Status"
if ! command -v docker-compose &> /dev/null; then
  echo "❌ Docker Compose is not installed"
else
  echo "✅ Docker Compose is installed"
  docker-compose --version
fi

# Check Hyperglass container status
print_header "Hyperglass Container Status"
if docker ps -a | grep -q hyperglass; then
  echo "✅ Hyperglass container exists"
  docker ps -a | grep hyperglass
else
  echo "❌ Hyperglass container not found"
fi

# Check Traefik container status
print_header "Traefik Container Status"
if docker ps -a | grep -q traefik; then
  echo "✅ Traefik container exists"
  docker ps -a | grep traefik
else
  echo "❌ Traefik container not found"
fi

# Check Redis container status
print_header "Redis Container Status"
if docker ps -a | grep -q redis; then
  echo "✅ Redis container exists"
  docker ps -a | grep redis
else
  echo "❌ Redis container not found"
fi

# Check BIRD socket accessibility
print_header "BIRD Socket Status"
BIRD_SOCKET="/var/run/bird/bird.ctl"
if [ -S "$BIRD_SOCKET" ]; then
  echo "✅ BIRD socket exists at $BIRD_SOCKET"
  ls -l "$BIRD_SOCKET"
  
  # Check permissions
  if [ "$(stat -c '%a' $BIRD_SOCKET)" = "666" ]; then
    echo "✅ BIRD socket has correct permissions (666)"
  else
    echo "❌ BIRD socket has incorrect permissions: $(stat -c '%a' $BIRD_SOCKET)"
  fi
  
  # Test BIRD socket
  echo "Testing BIRD socket connectivity..."
  echo "show status" | socat - UNIX-CONNECT:$BIRD_SOCKET | head -5
else
  echo "❌ BIRD socket not found at standard location"
  
  # Look for alternate locations
  FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
  if [ -n "$FOUND_SOCKET" ]; then
    echo "✅ Found BIRD socket at alternate location: $FOUND_SOCKET"
    ls -l "$FOUND_SOCKET"
    
    # Check permissions
    if [ "$(stat -c '%a' $FOUND_SOCKET)" = "666" ]; then
      echo "✅ BIRD socket has correct permissions (666)"
    else
      echo "❌ BIRD socket has incorrect permissions: $(stat -c '%a' $FOUND_SOCKET)"
    fi
    
    # Test BIRD socket
    echo "Testing BIRD socket connectivity..."
    echo "show status" | socat - UNIX-CONNECT:$FOUND_SOCKET | head -5
  else
    echo "❌ No BIRD socket found anywhere in /var/run"
  fi
fi

# Check BIRD proxy script
print_header "BIRD Proxy Script Status"
if [ -f "/usr/local/bin/hyperglass-bird" ]; then
  echo "✅ BIRD proxy script exists"
  ls -l /usr/local/bin/hyperglass-bird
  
  # Check permissions
  if [ -x "/usr/local/bin/hyperglass-bird" ]; then
    echo "✅ BIRD proxy script is executable"
  else
    echo "❌ BIRD proxy script is not executable"
  fi
  
  # Show script contents
  echo "BIRD proxy script contents:"
  cat /usr/local/bin/hyperglass-bird
else
  echo "❌ BIRD proxy script not found"
fi

# Check Hyperglass configuration
print_header "Hyperglass Configuration Status"
if [ -f "/etc/hyperglass/hyperglass.yaml" ]; then
  echo "✅ Hyperglass configuration exists"
  
  # Show brief summary
  echo "Configuration summary:"
  grep -A3 "site_title\|devices:" /etc/hyperglass/hyperglass.yaml
else
  echo "❌ Hyperglass configuration not found"
fi

# Check anycast IP configuration
print_header "Anycast IP Configuration"
if ip link show | grep -q dummy0; then
  echo "✅ Dummy0 interface exists"
  ip addr show dummy0
else
  echo "❌ Dummy0 interface not found"
fi

# Check firewall rules for port 8080
print_header "Firewall Rules for Port 8080"
if command -v ufw &> /dev/null; then
  echo "UFW status:"
  ufw status | grep 8080 || echo "No specific rules for port 8080"
else
  echo "❌ UFW not installed"
fi

# Check Docker networks
print_header "Docker Networks"
docker network ls

# Check memory and CPU usage
print_header "System Resources"
echo "Memory usage:"
free -h

echo -e "\nCPU load:"
uptime

echo -e "\nDisk space:"
df -h /

# Check if Hyperglass service is accessible locally
print_header "Hyperglass Local Access Check"
if curl -s -I http://localhost:8080 > /dev/null; then
  echo "✅ Hyperglass is accessible locally"
  curl -s -I http://localhost:8080 | head -5
else
  echo "❌ Hyperglass is not accessible locally"
fi

# Check Traefik dashboard access
print_header "Traefik Status"
if curl -s -I http://localhost:8080/api/rawdata > /dev/null; then
  echo "✅ Traefik API is accessible"
else
  echo "❌ Traefik API is not accessible"
fi

# Check SSL certificate status
print_header "SSL Certificate Status"
if [ -f "/var/www/acme/acme.json" ]; then
  echo "✅ ACME certificate storage exists"
  ls -la /var/www/acme/acme.json
else
  echo "❌ ACME certificate storage not found"
fi

print_header "Container Logs"
echo "Hyperglass logs (last 10 lines):"
docker logs hyperglass --tail 10 2>/dev/null || echo "❌ Cannot retrieve Hyperglass logs"

echo -e "\nTraefik logs (last 10 lines):"
docker logs traefik --tail 10 2>/dev/null || echo "❌ Cannot retrieve Traefik logs"

print_header "Systemd Service Status"
if [ -f "/etc/systemd/system/hyperglass.service" ]; then
  echo "✅ Hyperglass systemd service exists"
  systemctl status hyperglass.service --no-pager || echo "Service not active"
else
  echo "❌ Hyperglass systemd service not found"
fi
EOT

  # Make the script executable
  chmod +x /tmp/check_hyperglass.sh
  
  # Copy the script to the server and execute it
  scp -o StrictHostKeyChecking=no /tmp/check_hyperglass.sh root@$server_ip:/tmp/
  ssh -o StrictHostKeyChecking=no root@$server_ip 'bash /tmp/check_hyperglass.sh'
  
  echo -e "${GREEN}=== End of status report for $server_name server ===${NC}"
  echo
}

# Main execution flow
echo -e "${MAGENTA}=== Hyperglass Deployment Status Check ===${NC}"
echo -e "${BLUE}This script will check the status of Hyperglass on all BGP speakers.${NC}"
echo -e "${BLUE}Servers to check:${NC}"
for i in "${!SERVER_IPS[@]}"; do
  echo -e "  ${CYAN}${SERVER_NAMES[$i]}:${NC} ${SERVER_IPS[$i]}"
done
echo

# Process each server
for i in "${!SERVER_IPS[@]}"; do
  SERVER_IP=${SERVER_IPS[$i]}
  SERVER_NAME=${SERVER_NAMES[$i]}
  
  echo -e "${MAGENTA}=== Checking $SERVER_NAME server ($SERVER_IP) ===${NC}"
  
  check_hyperglass_status "$SERVER_IP" "$SERVER_NAME"
done

echo -e "${MAGENTA}=== Status Check Summary ===${NC}"
echo -e "${BLUE}The looking glass is accessible at:${NC} ${GREEN}https://$SUBDOMAIN.$DOMAIN${NC}"
echo -e "${BLUE}You can verify it's working properly by visiting this URL in your browser.${NC}"
echo -e "${BLUE}Anycast routing will direct you to your closest BGP speaker.${NC}"
echo
echo -e "${GREEN}Status check complete!${NC}"