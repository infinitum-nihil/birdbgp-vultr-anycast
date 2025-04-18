#!/bin/bash
# Script to fix IPv6 BGP configuration

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

echo "Fixing IPv6 BGP configuration on $LAX_IP..."

# Connect to the IPv6 server and check network information
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "
  echo 'Checking network interfaces...'
  ip addr show
  echo
  echo 'Checking routing table...'
  ip -6 route show
  echo
  echo 'Checking for link-local address...'
  MAIN_IF=\$(ip -br link | grep -v 'lo' | head -1 | awk '{print \$1}')
  echo \"Main interface: \$MAIN_IF\"
  LINK_LOCAL=\$(ip -6 addr show dev \$MAIN_IF | grep -i 'fe80' | awk '{print \$2}' | cut -d'/' -f1)
  echo \"Link-local address: \$LINK_LOCAL\"
  
  # Create an improved Bird config for IPv6
  cat > /etc/bird/bird.conf << 'EOF'
# BIRD 2.0.8 Configuration for IPv6 BGP Server

# Global configuration
router id 149.248.2.74;
log syslog { info, remote, warning, error, auth, fatal, bug };
protocol device {
    scan time 10;
}

# Direct protocol to use interfaces
protocol direct {
    ipv6;
    interface \"dummy*\", \"enp1s0\";
}

# Define networks to announce
protocol static {
    ipv6 {
        export all;
    };
    route 2620:71:4000::/48 blackhole;
}

# IPv6 BGP configuration
protocol bgp vultr6 {
    description \"vultr\";
    local as 27218;
    neighbor 2001:19f0:ffff::1 as 64515;
    multihop 2;
    password \"xV72GUaFMSYxNmee\";
    ipv6 {
        import all;
        export where source ~ [ RTS_DEVICE, RTS_STATIC ];
    };
}
EOF

  # Verify that the configuration is valid
  bird -p
  
  # Restart BIRD service
  systemctl restart bird
  
  echo 'Waiting for BGP session to establish...'
  sleep 15
  
  # Check BIRD status
  echo 'BIRD status:'
  systemctl status bird
  
  echo 'BGP status:'
  birdc show protocols all vultr6
"

echo "IPv6 BGP configuration fixed on $LAX_IP"