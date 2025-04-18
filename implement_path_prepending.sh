#!/bin/bash
# Script to implement path prepending for the secondary and tertiary BGP servers

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

MIA_IP=$(cat "$(dirname "$0")/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
ORD_IP=$(cat "$(dirname "$0")/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)

echo "Implementing BGP path prepending..."

# Update secondary server with 1x path prepending
echo "Configuring 1x path prepending on Secondary (MIA) server at $MIA_IP..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$MIA_IP "
  cat > /etc/bird/bird.conf << 'EOF'
# BIRD 2.0.8 Configuration for Secondary IPv4 BGP Server with Path Prepending

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
        # Add 1x path prepending for secondary server
        export filter {
            if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
                # Prepend our own ASN once for secondary server
                bgp_path.prepend(27218);
                accept;
            } else {
                reject;
            }
        };
    };
    graceful restart on;
    multihop 2;
    neighbor 169.254.169.254 as 64515;
    password \"xV72GUaFMSYxNmee\";
}
EOF

  # Verify the configuration
  bird -p
  
  # Restart BIRD
  systemctl restart bird
  
  # Check status
  echo 'Secondary BGP with 1x prepend status:'
  birdc show protocols vultr
"

# Update tertiary server with 2x path prepending
echo "Configuring 2x path prepending on Tertiary (ORD) server at $ORD_IP..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$ORD_IP "
  cat > /etc/bird/bird.conf << 'EOF'
# BIRD 2.0.8 Configuration for Tertiary IPv4 BGP Server with Path Prepending

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
        # Add 2x path prepending for tertiary server
        export filter {
            if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
                # Prepend our own ASN twice for tertiary server
                bgp_path.prepend(27218);
                bgp_path.prepend(27218);
                accept;
            } else {
                reject;
            }
        };
    };
    graceful restart on;
    multihop 2;
    neighbor 169.254.169.254 as 64515;
    password \"xV72GUaFMSYxNmee\";
}
EOF

  # Verify the configuration
  bird -p
  
  # Restart BIRD
  systemctl restart bird
  
  # Check status
  echo 'Tertiary BGP with 2x prepend status:'
  birdc show protocols vultr
"

echo "Path prepending implemented on secondary and tertiary BGP servers"