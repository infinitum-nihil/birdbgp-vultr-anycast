#!/bin/bash
# Script to fix BIRD configuration with log directory permissions

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create fix script for BIRD
cat > /tmp/fix_bird_final.sh << 'EOF'
#!/bin/bash
set -e

echo "Creating log directory with proper permissions..."
mkdir -p /var/log/bird
chown bird:bird /var/log/bird
chmod 755 /var/log/bird

echo "Creating backup of existing BIRD configuration..."
cp /etc/bird.conf /etc/bird.conf.bak.$(date +%s)

echo "Creating fixed BIRD configuration..."
cat > /etc/bird.conf << 'BIRD_CONF'
# BIRD Configuration File for LAX Primary BGP (BIRD 2.0.8)
# Role: Primary (no prepending)

# Log configuration
log syslog all;

# Router ID - using the primary IP of the server
router id 149.248.2.74;

# Configure BGP filters
filter export_bgp_filter {
    # Only announce what we're authorized to announce
    if net ~ [ 192.30.120.10/32 ] then accept;
    if net ~ [ 2620:71:4000::c01e:780a/128 ] then accept;
    reject;
}

# Configure BGP protocol for IPv4
protocol bgp vultr4 {
    description "IPv4 BGP session with Vultr";
    local as 27218;
    neighbor 149.248.2.1 as 64515;
    password "your_bgp_password";
    
    hold time 90;
    keepalive time 30;
    
    ipv4 {
        import all;
        export filter export_bgp_filter;
        next hop self;
    };
}

# Configure BGP protocol for IPv6
protocol bgp vultr6 {
    description "IPv6 BGP session with Vultr";
    local as 27218;
    neighbor 2001:19f0:ffff::1 as 64515;
    multihop;
    password "your_bgp_password";
    
    hold time 90;
    keepalive time 30;
    
    ipv6 {
        import all;
        export filter export_bgp_filter;
        next hop self;
    };
}

# Configure direct protocol
protocol direct {
    ipv4;
    ipv6;
}

# Configure kernel protocol for IPv4
protocol kernel {
    ipv4 {
        import all;
        export all;
    };
}

# Configure kernel protocol for IPv6
protocol kernel {
    ipv6 {
        import all;
        export all;
    };
}

# Configure device protocol
protocol device {
}

# Static routes for anycast IPs
protocol static {
    ipv4;
    route 192.30.120.10/32 blackhole;
}

protocol static {
    ipv6;
    route 2620:71:4000::c01e:780a/128 blackhole;
}
BIRD_CONF

echo "Restarting BIRD service..."
systemctl restart bird

echo "Checking BIRD service status..."
sleep 2
systemctl status bird

#!/bin/bash

BIRD_SOCKET="/var/run/bird/bird.ctl"

if [ ! -S "$BIRD_SOCKET" ]; then
  echo "Error: BIRD socket not found at $BIRD_SOCKET"
  exit 1
fi

# Get command from stdin 
read -r command

# Pass to BIRD socket with error handling
echo "$command" | socat -t 5 - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null || 
  echo "Error: Failed to connect to BIRD socket"
BIRDSCRIPT


echo "Testing BIRD socket proxy..."
if [ -e "/var/run/bird/bird.ctl" ]; then
    echo "show status" | socat - UNIX-CONNECT:/var/run/bird/bird.ctl
else
    echo "BIRD socket not found at /var/run/bird/bird.ctl"
fi


echo "BIRD configuration fixed"
EOF

chmod +x /tmp/fix_bird_final.sh

# Upload and execute on LAX server
echo "Uploading BIRD fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_bird_final.sh root@$LAX_IP:/tmp/fix_bird_final.sh

echo "Executing BIRD fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_bird_final.sh"

echo "BIRD configuration fixed"