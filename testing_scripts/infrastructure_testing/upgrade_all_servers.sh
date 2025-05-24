#!/bin/bash
# Script to upgrade all BGP servers to BIRD 2.16.2 with dual-stack support where available
source "$(dirname "$0")/.env"

# Define server IPs
EWR_IP="66.135.18.138"  # Primary
MIA_IP="149.28.108.180"  # Secondary
ORD_IP="66.42.113.101"   # Tertiary
LAX_IP="149.248.2.74"    # IPv6

echo "=== BGP Upgrade and Dual-Stack Configuration ==="
echo "This script will:"
echo "1. Upgrade all servers to BIRD 2.16.2"
echo "2. Configure dual-stack BGP where IPv6 is available"
echo "3. Maintain proper path prepending hierarchy"
echo

# Confirm before proceeding
read -p "Are you sure you want to proceed? This will temporarily disrupt BGP sessions! (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
  echo "Operation canceled."
  exit 1
fi

# Function to upgrade BIRD and apply configuration
upgrade_and_configure() {
  local server_ip=$1
  local server_name=$2
  local server_priority=$3
  local config_file=$4
  
  echo
  echo "=== Processing $server_name ($server_ip) ==="
  
  # Copy configuration file
  echo "Copying $server_name configuration to server..."
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" $config_file root@$server_ip:/etc/bird/bird.conf.new
  
  # Upgrading and configuring BIRD on server
  echo "Upgrading BIRD and applying configuration on $server_name..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip << EOF
    echo "Stopping BIRD service..."
    systemctl stop bird
    
    echo "Installing build dependencies..."
    apt-get update
    apt-get install -y build-essential flex bison autoconf libncurses-dev libreadline-dev git wget
    
    echo "Downloading and building BIRD 2.16.2..."
    mkdir -p /tmp/bird-build
    cd /tmp/bird-build
    wget -q https://bird.network.cz/download/bird-2.16.2.tar.gz
    tar xzf bird-2.16.2.tar.gz
    cd bird-2.16.2
    autoreconf
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var
    make
    
    echo "Backing up existing configuration..."
    cp /etc/bird/bird.conf /etc/bird/bird.conf.bak.$(date +%s)
    
    echo "Installing BIRD 2.16.2..."
    make install
    
    echo "Creating bird directory if it doesn't exist..."
    mkdir -p /etc/bird
    
    echo "Applying new configuration..."
    mv /etc/bird/bird.conf.new /etc/bird/bird.conf
    
    echo "Checking IPv6 connectivity..."
    if ping6 -c 1 2001:19f0:ffff::1 > /dev/null 2>&1; then
      echo "IPv6 connectivity available!"
    else
      echo "No IPv6 connectivity - server will only use IPv4 BGP"
    fi
    
    echo "Restarting BIRD service..."
    systemctl restart bird
    sleep 5
    
    echo "Checking BIRD status..."
    systemctl status bird | grep Active
    
    echo "Checking BGP protocols..."
    birdc show protocols | grep -E "BGP|Name"
EOF
  
  echo "=== $server_name processing completed ==="
  echo
}

# Create configuration files for each server
echo "Creating configuration files..."

# Primary server (EWR) - No path prepending
cat > /tmp/bird_ewr.conf << 'EOF'
# BIRD 2.16.2 Configuration for Primary BGP Server
router id 66.135.18.138;
log syslog all;

# Define our ASN and peer ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

# Define our prefixes
define OUR_IPV4_PREFIX = 192.30.120.0/23;
define OUR_IPV6_PREFIX = 2620:71:4000::/48;

# Common protocol configuration
protocol device { }

# Direct protocol for IPv4
protocol direct v4direct {
  ipv4;
  interface "dummy*", "enp1s0";
}

# Kernel protocol for IPv4
protocol kernel v4kernel {
  ipv4 {
    export all;
  };
}

# Static routes for IPv4
protocol static v4static {
  ipv4;
  route OUR_IPV4_PREFIX blackhole;
}

# IPv4 BGP configuration - Primary (no path prepending)
protocol bgp vultr_v4 {
  description "Vultr IPv4 BGP";
  local as OUR_ASN;
  neighbor 169.254.169.254 as VULTR_ASN;
  multihop 2;
  password "xV72GUaFMSYxNmee";
  ipv4 {
    import none;
    export where proto = "v4static";
  };
}

# Try to set up IPv6 BGP if connectivity exists
# This will be skipped if IPv6 is not available, but doesn't hurt to include
protocol direct v6direct {
  ipv6;
  interface "dummy*", "enp1s0";
}

protocol kernel v6kernel {
  ipv6 {
    export all;
  };
}

protocol static v6static {
  ipv6;
  route OUR_IPV6_PREFIX blackhole;
}

protocol bgp vultr_v6 {
  description "Vultr IPv6 BGP";
  local as OUR_ASN;
  neighbor 2001:19f0:ffff::1 as VULTR_ASN;
  multihop 2;
  password "xV72GUaFMSYxNmee";
  ipv6 {
    import none;
    export where proto = "v6static";
  };
}
EOF

# Secondary server (MIA) - 1x path prepending
cat > /tmp/bird_mia.conf << 'EOF'
# BIRD 2.16.2 Configuration for Secondary BGP Server (1x Path Prepending)
router id 149.28.108.180;
log syslog all;

# Define our ASN and peer ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

# Define our prefixes
define OUR_IPV4_PREFIX = 192.30.120.0/23;
define OUR_IPV6_PREFIX = 2620:71:4000::/48;

# Common protocol configuration
protocol device { }

# Direct protocol for IPv4
protocol direct v4direct {
  ipv4;
  interface "dummy*", "enp1s0";
}

# Kernel protocol for IPv4
protocol kernel v4kernel {
  ipv4 {
    export all;
  };
}

# Static routes for IPv4
protocol static v4static {
  ipv4;
  route OUR_IPV4_PREFIX blackhole;
}

# IPv4 BGP configuration - Secondary (1x path prepending)
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
        # Add our AS once to path (1x prepend)
        bgp_path.prepend(OUR_ASN);
        accept;
      }
      else reject;
    };
  };
}

# Try to set up IPv6 BGP if connectivity exists
# This will be skipped if IPv6 is not available, but doesn't hurt to include
protocol direct v6direct {
  ipv6;
  interface "dummy*", "enp1s0";
}

protocol kernel v6kernel {
  ipv6 {
    export all;
  };
}

protocol static v6static {
  ipv6;
  route OUR_IPV6_PREFIX blackhole;
}

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
        # Add our AS once to path (1x prepend)
        bgp_path.prepend(OUR_ASN);
        accept;
      }
      else reject;
    };
  };
}
EOF

# Tertiary server (ORD) - 2x path prepending
cat > /tmp/bird_ord.conf << 'EOF'
# BIRD 2.16.2 Configuration for Tertiary BGP Server (2x Path Prepending)
router id 66.42.113.101;
log syslog all;

# Define our ASN and peer ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

# Define our prefixes
define OUR_IPV4_PREFIX = 192.30.120.0/23;
define OUR_IPV6_PREFIX = 2620:71:4000::/48;

# Common protocol configuration
protocol device { }

# Direct protocol for IPv4
protocol direct v4direct {
  ipv4;
  interface "dummy*", "enp1s0";
}

# Kernel protocol for IPv4
protocol kernel v4kernel {
  ipv4 {
    export all;
  };
}

# Static routes for IPv4
protocol static v4static {
  ipv4;
  route OUR_IPV4_PREFIX blackhole;
}

# IPv4 BGP configuration - Tertiary (2x path prepending)
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
        # Add our AS twice to path (2x prepend)
        bgp_path.prepend(OUR_ASN);
        bgp_path.prepend(OUR_ASN);
        accept;
      }
      else reject;
    };
  };
}

# Try to set up IPv6 BGP if connectivity exists
# This will be skipped if IPv6 is not available, but doesn't hurt to include
protocol direct v6direct {
  ipv6;
  interface "dummy*", "enp1s0";
}

protocol kernel v6kernel {
  ipv6 {
    export all;
  };
}

protocol static v6static {
  ipv6;
  route OUR_IPV6_PREFIX blackhole;
}

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
        # Add our AS twice to path (2x prepend)
        bgp_path.prepend(OUR_ASN);
        bgp_path.prepend(OUR_ASN);
        accept;
      }
      else reject;
    };
  };
}
EOF

# LAX server - Known working config with dual-stack (2x path prepending)
cat > /tmp/bird_lax.conf << 'EOF'
# BIRD 2.16.2 Configuration for LAX Server (Dual-Stack with 2x Path Prepending)
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

# Process each server one by one
echo "Starting server upgrades in the following order:"
echo "1. Secondary (MIA) - To minimize disruption"
echo "2. Tertiary (ORD) - To maintain backup routes"
echo "3. LAX (IPv6) - Already configured and tested"
echo "4. Primary (EWR) - Last to minimize downtime"
echo 

# Process servers in order to minimize downtime
upgrade_and_configure "$MIA_IP" "Secondary (MIA)" "1x_prepend" "/tmp/bird_mia.conf"
upgrade_and_configure "$ORD_IP" "Tertiary (ORD)" "2x_prepend" "/tmp/bird_ord.conf"
upgrade_and_configure "$LAX_IP" "IPv6 (LAX)" "2x_prepend" "/tmp/bird_lax.conf"
upgrade_and_configure "$EWR_IP" "Primary (EWR)" "no_prepend" "/tmp/bird_ewr.conf"

echo "All servers have been upgraded to BIRD 2.16.2 with appropriate configurations."
echo "Running BGP summary to verify status..."
echo

# Run BGP summary to check status
./bgp_summary.sh