#!/bin/bash
# Script to test dual-stack BGP configuration on the LAX server with the latest BIRD
source "$(dirname "$0")/.env"

LAX_IP="149.248.2.74"

echo "Creating improved dual-stack BIRD configuration for the LAX server..."

# Create the dual-stack BIRD config
cat > /tmp/bird_lax_dualstack.conf << 'EOF'
# BIRD 2.16.2 Configuration for IPv6 Server (Advanced Dual-Stack)
router id 149.248.2.74;
log syslog all;

# Define our ASN and peer ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

# Define our prefixes
define OUR_IPV4_PREFIX = 192.30.120.0/23;
define OUR_IPV6_PREFIX = 2620:71:4000::/48;

# Common configuration for all protocols
protocol device { }

# Direct protocol for IPv4
protocol direct v4direct {
  ipv4;
  interface "dummy*", "enp1s0";
}

# Direct protocol for IPv6
protocol direct v6direct {
  ipv6;
  interface "dummy*", "enp1s0";
}

# Kernel protocol for IPv4
protocol kernel v4kernel {
  ipv4 {
    export all;
  };
}

# Kernel protocol for IPv6
protocol kernel v6kernel {
  ipv6 {
    export all;
  };
}

# Static routes for IPv4
protocol static v4static {
  ipv4;
  route OUR_IPV4_PREFIX blackhole;
}

# Static routes for IPv6
protocol static v6static {
  ipv6;
  route OUR_IPV6_PREFIX blackhole;
}

# IPv4 BGP configuration - with 2x path prepending for consistency
protocol bgp vultr_v4 {
  description "Vultr IPv4 BGP";
  local as OUR_ASN;
  neighbor 169.254.169.254 as VULTR_ASN;
  multihop 2;
  password "xV72GUaFMSYxNmee";
  ipv4 {
    import none;
    export filter {
      if proto = "v4static" then {
        # Add 2x path prepending for consistency with IPv6
        bgp_path.prepend(OUR_ASN);
        bgp_path.prepend(OUR_ASN);
        accept;
      }
      else reject;
    };
  };
}

# IPv6 BGP configuration - with 2x path prepending
protocol bgp vultr_v6 {
  description "Vultr IPv6 BGP";
  local as OUR_ASN;
  neighbor 2001:19f0:ffff::1 as VULTR_ASN;
  multihop 2;
  password "xV72GUaFMSYxNmee";
  ipv6 {
    import none;
    export filter {
      if proto = "v6static" then {
        # Add our AS number twice to the path (2x prepend)
        bgp_path.prepend(OUR_ASN);
        bgp_path.prepend(OUR_ASN);
        accept;
      }
      else reject;
    };
  };
}
EOF

# First, upgrade BIRD on LAX
echo "Upgrading BIRD to version 2.16.2 on LAX server..."

read -p "Do you want to upgrade BIRD to 2.16.2 before testing dual-stack? (y/n): " upgrade_first

if [[ "$upgrade_first" == "y" ]]; then
  # Upgrade BIRD to latest version
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
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
    
    # Check new version
    echo "Verifying BIRD version:"
    birdc show status
EOF
fi

# Copy and apply the dual-stack configuration
echo "Copying dual-stack config to LAX server..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/bird_lax_dualstack.conf root@$LAX_IP:/etc/bird/bird.conf

# Restart BIRD service
echo "Restarting BIRD service on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP "systemctl restart bird && sleep 10"

# Check BGP status
echo "Checking BGP status on LAX server..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
echo "BIRD daemon status:"
systemctl status bird | grep Active

echo "BGP IPv4 status:"
birdc show protocols all vultr_v4

echo "BGP IPv6 status:"
birdc show protocols all vultr_v6

echo "Route status:"
birdc show route count
EOF

echo "Dual-stack BIRD test completed on LAX server."
echo "If successful, we can update deploy.sh to incorporate dual-stack support for all servers."