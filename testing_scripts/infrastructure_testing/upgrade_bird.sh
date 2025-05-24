#!/bin/bash
# Script to upgrade to latest BIRD version (2.16.2) from source
source "$(dirname "$0")/.env"

# Get region information from .env file
if [ -z "$BGP_REGION_PRIMARY" ] || [ -z "$BGP_REGION_SECONDARY" ] || [ -z "$BGP_REGION_TERTIARY" ] || [ -z "$BGP_REGION_QUATERNARY" ]; then
  echo "Error: One or more BGP regions are not defined in .env file"
  echo "Please ensure BGP_REGION_PRIMARY, BGP_REGION_SECONDARY, BGP_REGION_TERTIARY, and BGP_REGION_QUATERNARY are set"
  exit 1
fi

# Define server IPs based on region configuration
PRIMARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_PRIMARY}-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
SECONDARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_SECONDARY}-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
TERTIARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_TERTIARY}-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
QUATERNARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_QUATERNARY}-ipv4-bgp-quaternary-1c1g_ipv4.txt" 2>/dev/null)

if [ -z "$PRIMARY_IP" ] || [ -z "$SECONDARY_IP" ] || [ -z "$TERTIARY_IP" ] || [ -z "$QUATERNARY_IP" ]; then
  echo "Error: Could not find all required IPs in IP files."
  echo "Found: PRIMARY(${BGP_REGION_PRIMARY})=$PRIMARY_IP, SECONDARY(${BGP_REGION_SECONDARY})=$SECONDARY_IP, TERTIARY(${BGP_REGION_TERTIARY})=$TERTIARY_IP, QUATERNARY(${BGP_REGION_QUATERNARY})=$QUATERNARY_IP"
  exit 1
fi

# Define build function
build_bird() {
  local server_ip=$1
  local server_name=$2
  
  echo "=== Upgrading BIRD on $server_name ($server_ip) ==="
  
  # Create and execute remote script
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip << 'EOF'
    # Stop current BIRD service
    echo "Stopping current BIRD service..."
    systemctl stop bird
    
    # Install build dependencies
    echo "Installing build dependencies..."
    apt-get update
    apt-get install -y build-essential flex bison autoconf libncurses-dev libreadline-dev git
    
    # Create build directory
    echo "Setting up build directory..."
    mkdir -p /tmp/bird-build
    cd /tmp/bird-build
    
    # Download latest BIRD source
    echo "Downloading BIRD 2.16.2 source..."
    wget https://bird.network.cz/download/bird-2.16.2.tar.gz
    tar xzf bird-2.16.2.tar.gz
    cd bird-2.16.2
    
    # Configure and build
    echo "Configuring and building BIRD..."
    autoreconf
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var
    make
    
    # Backup existing configuration
    echo "Backing up existing configuration..."
    cp /etc/bird/bird.conf /etc/bird/bird.conf.bak.$(date +%s)
    
    # Install the new version
    echo "Installing BIRD 2.16.2..."
    make install
    
    # Create bird directory if it doesn't exist
    mkdir -p /etc/bird
    
    # Restart BIRD
    echo "Restarting BIRD service..."
    systemctl restart bird
    
    # Check new version
    echo "Verifying BIRD version:"
    birdc show status
EOF
  
  echo "=== BIRD upgrade completed on $server_name ($server_ip) ==="
  echo
}

# Execute the upgrade on each server
echo "Starting BIRD upgrade process to version 2.16.2..."
echo

# Ask which servers to upgrade
read -p "Upgrade Primary (${BGP_REGION_PRIMARY}) server? (y/n): " upgrade_primary
read -p "Upgrade Secondary (${BGP_REGION_SECONDARY}) server? (y/n): " upgrade_secondary
read -p "Upgrade Tertiary (${BGP_REGION_TERTIARY}) server? (y/n): " upgrade_tertiary
read -p "Upgrade Quaternary (${BGP_REGION_QUATERNARY}) server? (y/n): " upgrade_quaternary

# Confirm before proceeding
echo
echo "Ready to upgrade BIRD on the following servers:"
[[ "$upgrade_primary" == "y" ]] && echo "- Primary (${BGP_REGION_PRIMARY}): $PRIMARY_IP"
[[ "$upgrade_secondary" == "y" ]] && echo "- Secondary (${BGP_REGION_SECONDARY}): $SECONDARY_IP"
[[ "$upgrade_tertiary" == "y" ]] && echo "- Tertiary (${BGP_REGION_TERTIARY}): $TERTIARY_IP"
[[ "$upgrade_quaternary" == "y" ]] && echo "- Quaternary (${BGP_REGION_QUATERNARY}): $QUATERNARY_IP"
echo
read -p "Proceed with upgrade? This will temporarily disrupt BGP sessions! (y/n): " confirm

if [[ "$confirm" != "y" ]]; then
  echo "Upgrade canceled."
  exit 1
fi

# Perform upgrades
[[ "$upgrade_primary" == "y" ]] && build_bird "$PRIMARY_IP" "Primary (${BGP_REGION_PRIMARY})"
[[ "$upgrade_secondary" == "y" ]] && build_bird "$SECONDARY_IP" "Secondary (${BGP_REGION_SECONDARY})"
[[ "$upgrade_tertiary" == "y" ]] && build_bird "$TERTIARY_IP" "Tertiary (${BGP_REGION_TERTIARY})"
[[ "$upgrade_quaternary" == "y" ]] && build_bird "$QUATERNARY_IP" "Quaternary (${BGP_REGION_QUATERNARY})"

echo "BIRD upgrade process completed."
echo "Run ./bgp_summary.sh to check BGP status with the new BIRD version."