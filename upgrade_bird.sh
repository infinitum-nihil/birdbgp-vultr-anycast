#!/bin/bash
# Script to upgrade to latest BIRD version (2.16.2) from source
source "$(dirname "$0")/.env"

# Define server IPs
EWR_IP="66.135.18.138"
MIA_IP="149.28.108.180"
ORD_IP="66.42.113.101"
LAX_IP="149.248.2.74"

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
read -p "Upgrade Primary (EWR) server? (y/n): " upgrade_ewr
read -p "Upgrade Secondary (MIA) server? (y/n): " upgrade_mia
read -p "Upgrade Tertiary (ORD) server? (y/n): " upgrade_ord
read -p "Upgrade IPv6 (LAX) server? (y/n): " upgrade_lax

# Confirm before proceeding
echo
echo "Ready to upgrade BIRD on the following servers:"
[[ "$upgrade_ewr" == "y" ]] && echo "- Primary (EWR): $EWR_IP"
[[ "$upgrade_mia" == "y" ]] && echo "- Secondary (MIA): $MIA_IP"
[[ "$upgrade_ord" == "y" ]] && echo "- Tertiary (ORD): $ORD_IP"
[[ "$upgrade_lax" == "y" ]] && echo "- IPv6 (LAX): $LAX_IP"
echo
read -p "Proceed with upgrade? This will temporarily disrupt BGP sessions! (y/n): " confirm

if [[ "$confirm" != "y" ]]; then
  echo "Upgrade canceled."
  exit 1
fi

# Perform upgrades
[[ "$upgrade_ewr" == "y" ]] && build_bird "$EWR_IP" "Primary (EWR)"
[[ "$upgrade_mia" == "y" ]] && build_bird "$MIA_IP" "Secondary (MIA)"
[[ "$upgrade_ord" == "y" ]] && build_bird "$ORD_IP" "Tertiary (ORD)"
[[ "$upgrade_lax" == "y" ]] && build_bird "$LAX_IP" "IPv6 (LAX)"

echo "BIRD upgrade process completed."
echo "Run ./bgp_summary.sh to check BGP status with the new BIRD version."