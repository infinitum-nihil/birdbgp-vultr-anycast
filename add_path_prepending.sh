#!/bin/bash
# Script to explicitly add path prepending to the BGP configurations

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# Get server IPs
EWR_IP=$(cat "$(dirname "$0")/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
MIA_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
ORD_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

echo "=== Confirming Path Prepending Configuration ==="

# Primary server - Check/update configuration (no prepending)
echo "Checking/updating Primary (EWR) server BGP configuration..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$EWR_IP "
  # Check if prepending is already configured
  if ! grep -q 'export where source' /etc/bird/bird.conf; then
    # Update the configuration
    cat > /etc/bird/bird.conf << 'EOF'
# BIRD 2.0.8 Configuration for Primary IPv4 BGP Server (NO Path Prepending)

# Global configuration
router id 66.135.18.138;
log syslog { info, remote, warning, error, auth, fatal, bug };
protocol device {
    scan time 10;
}

# Direct protocol to use interfaces
protocol direct {
    ipv4;
    interface \"dummy*\";
}

# Define networks to announce
protocol static {
    ipv4 {
        export all;
    };
    route 192.30.120.0/23 blackhole;
}

# BGP configuration for Vultr (Primary - No Path Prepending)
protocol bgp vultr {
    description \"vultr\";
    local as 27218;
    source address 66.135.18.138;
    ipv4 {
        import all;
        # Primary server - No prepending (highest priority route)
        export where source ~ [ RTS_DEVICE, RTS_STATIC ];
    };
    graceful restart on;
    multihop 2;
    neighbor 169.254.169.254 as 64515;
    password \"xV72GUaFMSYxNmee\";
}
EOF
    
    # Restart BIRD
    systemctl restart bird
    echo 'Primary configuration updated with explicit no prepending'
  else
    echo 'Primary configuration already has export filter defined'
  fi
  
  # Verify configuration
  echo 'Current export filter in Primary config:'
  grep -A 5 'export' /etc/bird/bird.conf
  
  # Check BGP status
  echo 'Primary BGP status:'
  birdc show protocols vultr
"

# Secondary server - Add 1x prepending
echo "Updating Secondary (MIA) server with 1x path prepending..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$MIA_IP "
  # Create a simpler but effective configuration
  cat > /etc/bird/bird.conf << 'EOF'
# BIRD 2.0.8 Configuration for Secondary IPv4 BGP Server (1x Path Prepending)

# Global configuration
router id 149.28.108.180;
log syslog { info, remote, warning, error, auth, fatal, bug };
protocol device {
    scan time 10;
}

# Direct protocol to use interfaces
protocol direct {
    ipv4;
    interface \"dummy*\";
}

# Define networks to announce
protocol static {
    ipv4 {
        export all;
    };
    route 192.30.120.0/23 blackhole;
}

# BGP configuration for Vultr with 1x path prepending
protocol bgp vultr {
    description \"vultr\";
    local as 27218;
    source address 149.28.108.180;
    ipv4 {
        import all;
        export filter {
            if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
                # Add our AS once to path (1x prepend)
                bgp_path.prepend(27218);
                accept;
            } else reject;
        };
    };
    graceful restart on;
    multihop 2;
    neighbor 169.254.169.254 as 64515;
    password \"xV72GUaFMSYxNmee\";
}
EOF
  
  # Restart BIRD
  systemctl restart bird
  
  # Verify configuration
  echo 'Secondary configuration updated with 1x prepending'
  echo 'Current export filter in Secondary config:'
  grep -A 9 'export filter' /etc/bird/bird.conf
  
  # Wait for BGP to establish
  sleep 5
  
  # Check BGP status
  echo 'Secondary BGP status:'
  birdc show protocols vultr
"

# Tertiary server - Add 2x prepending
echo "Updating Tertiary (ORD) server with 2x path prepending..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$ORD_IP "
  # Create a simpler but effective configuration
  cat > /etc/bird/bird.conf << 'EOF'
# BIRD 2.0.8 Configuration for Tertiary IPv4 BGP Server (2x Path Prepending)

# Global configuration
router id 66.42.113.101;
log syslog { info, remote, warning, error, auth, fatal, bug };
protocol device {
    scan time 10;
}

# Direct protocol to use interfaces
protocol direct {
    ipv4;
    interface \"dummy*\";
}

# Define networks to announce
protocol static {
    ipv4 {
        export all;
    };
    route 192.30.120.0/23 blackhole;
}

# BGP configuration for Vultr with 2x path prepending
protocol bgp vultr {
    description \"vultr\";
    local as 27218;
    source address 66.42.113.101;
    ipv4 {
        import all;
        export filter {
            if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
                # Add our AS twice to path (2x prepend)
                bgp_path.prepend(27218);
                bgp_path.prepend(27218);
                accept;
            } else reject;
        };
    };
    graceful restart on;
    multihop 2;
    neighbor 169.254.169.254 as 64515;
    password \"xV72GUaFMSYxNmee\";
}
EOF
  
  # Restart BIRD
  systemctl restart bird
  
  # Verify configuration
  echo 'Tertiary configuration updated with 2x prepending'
  echo 'Current export filter in Tertiary config:'
  grep -A 10 'export filter' /etc/bird/bird.conf
  
  # Wait for BGP to establish
  sleep 5
  
  # Check BGP status
  echo 'Tertiary BGP status:'
  birdc show protocols vultr
"

echo "Path prepending configuration has been explicitly applied to all IPv4 BGP servers"
echo "Wait a minute and then run ./check_bgp_status.sh to verify the configuration"