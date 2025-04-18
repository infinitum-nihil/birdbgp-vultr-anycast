#!/bin/bash
# Advanced script to fix IPv6 BGP configuration with extensive diagnostics

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

echo "Advanced IPv6 BGP fix for $LAX_IP..."

# Connect to the IPv6 server and perform diagnostics and fix
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "
  echo 'Running extended diagnostics...'
  
  echo '=== Network Interfaces ==='
  ip addr show
  
  echo '=== IPv6 Routing Table ==='
  ip -6 route show
  
  echo '=== IPv6 Neighbor Table ==='
  ip -6 neigh show
  
  echo '=== MTU Settings ==='
  ip link show | grep mtu
  
  echo '=== Testing IPv6 Connectivity ==='
  ping6 -c 3 2001:19f0:ffff::1 || echo 'Cannot ping BGP peer'
  
  echo '=== Testing DNS Resolution ==='
  host -t AAAA google.com || echo 'DNS AAAA resolution failing'
  
  echo '=== Firewall Status ==='
  iptables -L -n
  ip6tables -L -n
  
  echo '=== Creating very simple BIRD config optimized for IPv6 ==='
  cat > /etc/bird/bird.conf << 'EOF'
# BIRD 2.0.8 Configuration for IPv6 BGP
# Updated configuration with enhanced connection parameters

# Global configuration
router id 149.248.2.74;
log syslog { debug, trace, info, remote, warning, error, auth, fatal, bug };
debug protocols all;

# Define our ASN and Vultr's ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

# Set the IPv6 prefix we're announcing
define OUR_PREFIX = 2620:71:4000::/48;

# Device protocol
protocol device {
  scan time 10;
}

# Direct protocol for interfaces
protocol direct {
  ipv6;
  interface \"lo\", \"enp1s0\", \"dummy*\";
}

# Kernel protocol
protocol kernel {
  ipv6 {
    export all;
  };
  merge paths;
}

# Static route for our prefix
protocol static {
  ipv6;
  route OUR_PREFIX blackhole;
}

# BGP for IPv6
protocol bgp vultr6 {
  description \"Vultr IPv6 BGP\";
  local as OUR_ASN;
  neighbor 2001:19f0:ffff::1 as VULTR_ASN;
  
  startup delay 5;
  connect delay time 5;
  connect retry time 5;
  error wait time 5, 10;
  
  multihop 2;
  password \"xV72GUaFMSYxNmee\";
  
  hold time 90;
  keepalive time 30;
  
  graceful restart on;
  
  ipv6 {
    import none;
    export where source ~ [ RTS_STATIC ];
    next hop self;
  };
}
EOF

  echo '=== Testing BIRD configuration ==='
  bird -p

  echo '=== Stopping and cleaning up BIRD ==='
  systemctl stop bird
  killall -9 bird || true
  rm -rf /run/bird
  mkdir -p /run/bird
  chown bird:bird /run/bird
  
  echo '=== Starting BIRD in debug mode ==='
  systemctl start bird
  
  echo '=== Waiting for BGP session to establish... ==='
  sleep 10
  
  echo '=== BIRD Status ==='
  systemctl status bird
  
  echo '=== BGP Status ==='
  birdc show protocols all vultr6
  
  echo '=== Route Status ==='
  birdc show route all
  
  echo '=== Kernel Route Status ==='
  ip -6 route show
  
  echo '=== BGP Debug Information ==='
  birdc debug protocols all
  
  echo 'Advanced IPv6 BGP diagnostics and fixes complete.'
"

echo "IPv6 BGP advanced diagnostics and fixes applied."
echo "Recheck BGP status in a minute with ./check_bgp_status.sh"