#!/bin/bash
# Script to fix BIRD configuration on LAX server

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Create fix script for BIRD
cat > /tmp/fix_bird.sh << 'EOF'
#!/bin/bash
set -e

echo "Checking BIRD configuration..."
cat /etc/bird.conf

echo "Creating backup of existing BIRD configuration..."
cp /etc/bird.conf /etc/bird.conf.bak.$(date +%s)

echo "Fixing BIRD configuration..."

# Create a fixed configuration
cat > /etc/bird.conf << 'BIRD_CONF'
# BIRD Configuration File for LAX Primary BGP
# Role: Primary (no prepending)

# Log configuration
log syslog all;
log "/var/log/bird.log" { debug, trace, info, remote, warning, error, auth, fatal, bug };

# Router ID - using the primary IP of the server
router id 149.248.2.74;

# Debug options
debug protocols all;

# Configure timeouts
timeout graceful 30;

# Configure BGP filters
filter export_bgp_filter {
    # Only announce what we're authorized to announce
    if net ~ [ 192.30.120.10/32 ] then accept;
    if net ~ [ 2620:71:4000::c01e:780a/128 ] then accept;
    reject;
}

# Configure BGP protocol
protocol bgp vultr {
    description "BGP session with Vultr";
    local as 27218;
    neighbor 149.248.2.1 as 64515; # Vultr BGP ASN
    password "your_bgp_password";
    
    hold time 90;
    keepalive time 30;
    
    ipv4 {
        import all;
        export filter export_bgp_filter;
        next hop self;
    };

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

# Configure kernel synchronization
protocol kernel {
    ipv4 {
        export all;
    };
}

protocol kernel {
    ipv6 {
        export all;
    };
}

# Configure device protocol
protocol device {
    scan time 10;
}

# Static routes for anycast IPs
protocol static {
    ipv4;
    route 192.30.120.10/32 via "dummy0";
}

protocol static {
    ipv6;
    route 2620:71:4000::c01e:780a/128 via "dummy0";
}
BIRD_CONF

echo "Restarting BIRD service..."
systemctl restart bird

echo "Checking BIRD service status..."
systemctl status bird

echo "Testing BIRD socket proxy..."
echo "show status" | socat - UNIX-CONNECT:/var/run/bird/bird.ctl

echo "BIRD fix completed"
EOF

chmod +x /tmp/fix_bird.sh

# Upload and execute on LAX server
echo "Uploading BIRD fix script to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/fix_bird.sh root@$LAX_IP:/tmp/fix_bird.sh

echo "Executing BIRD fix script on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "bash /tmp/fix_bird.sh"

echo "BIRD configuration fixed"
