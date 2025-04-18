#!/bin/bash
# Script to add IPv6 configuration to all IPv4 servers
source "$(dirname "$0")/.env"

echo "Adding IPv6 BGP configuration to all servers..."

# Primary server (EWR) - Add IPv6 with no path prepending
cat > /tmp/bird_ewr_dual.conf << 'EOF'
# BIRD 2.0.8 Configuration for Primary BGP Server (Dual Stack)

# Global configuration
router id 66.135.18.138;
log syslog { info, remote, warning, error, auth, fatal, bug };

# Define our ASN and Vultr's ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

protocol device {
    scan time 10;
}

# Direct protocol for IPv4
protocol direct {
    ipv4;
    interface "dummy*";
}

# Direct protocol for IPv6
protocol direct v6direct {
    ipv6;
    interface "dummy*";
}

# Define IPv4 networks to announce
protocol static {
    ipv4 {
        export all;
    };
    route 192.30.120.0/23 blackhole;
}

# Define IPv6 networks to announce
protocol static v6static {
    ipv6 {
        export all;
    };
    route 2620:71:4000::/48 blackhole;
}

# BGP configuration for Vultr IPv4
protocol bgp vultr {
    description "vultr ipv4";
    local as OUR_ASN;
    source address 66.135.18.138;
    ipv4 {
        import all;
        export where source ~ [ RTS_DEVICE, RTS_STATIC ];
    };
    graceful restart on;
    multihop 2;
    neighbor 169.254.169.254 as VULTR_ASN;
    password "xV72GUaFMSYxNmee";
}

# BGP configuration for Vultr IPv6 - Primary (no path prepending)
protocol bgp vultr6 {
    description "vultr ipv6";
    local as OUR_ASN;
    ipv6 {
        import none;
        export where proto = "v6static";
    };
    graceful restart on;
    multihop 2;
    neighbor 2001:19f0:ffff::1 as VULTR_ASN;
    password "xV72GUaFMSYxNmee";
}
EOF

# Secondary server (MIA) - Add IPv6 with 1x path prepending
cat > /tmp/bird_mia_dual.conf << 'EOF'
# BIRD 2.0.8 Configuration for Secondary BGP Server (Dual Stack + Path Prepending)

# Global configuration
router id 149.28.108.180;
log syslog { info, remote, warning, error, auth, fatal, bug };

# Define our ASN and Vultr's ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

protocol device {
    scan time 10;
}

# Direct protocol for IPv4
protocol direct {
    ipv4;
    interface "dummy*";
}

# Direct protocol for IPv6
protocol direct v6direct {
    ipv6;
    interface "dummy*";
}

# Define IPv4 networks to announce
protocol static {
    ipv4 {
        export all;
    };
    route 192.30.120.0/23 blackhole;
}

# Define IPv6 networks to announce
protocol static v6static {
    ipv6 {
        export all;
    };
    route 2620:71:4000::/48 blackhole;
}

# BGP configuration for Vultr IPv4 with 1x path prepending
protocol bgp vultr {
    description "vultr ipv4";
    local as OUR_ASN;
    source address 149.28.108.180;
    ipv4 {
        import all;
        export filter {
            if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
                # Add our AS once to path (1x prepend)
                bgp_path.prepend(OUR_ASN);
                accept;
            } else reject;
        };
    };
    graceful restart on;
    multihop 2;
    neighbor 169.254.169.254 as VULTR_ASN;
    password "xV72GUaFMSYxNmee";
}

# BGP configuration for Vultr IPv6 with 1x path prepending
protocol bgp vultr6 {
    description "vultr ipv6";
    local as OUR_ASN;
    ipv6 {
        import none;
        export filter {
            if proto = "v6static" then {
                # Add our AS once to path (1x prepend)
                bgp_path.prepend(OUR_ASN);
                accept;
            } else reject;
        };
    };
    graceful restart on;
    multihop 2;
    neighbor 2001:19f0:ffff::1 as VULTR_ASN;
    password "xV72GUaFMSYxNmee";
}
EOF

# Tertiary server (ORD) - Add IPv6 with 2x path prepending
cat > /tmp/bird_ord_dual.conf << 'EOF'
# BIRD 2.0.8 Configuration for Tertiary BGP Server (Dual Stack + 2x Path Prepending)

# Global configuration
router id 66.42.113.101;
log syslog { info, remote, warning, error, auth, fatal, bug };

# Define our ASN and Vultr's ASN
define OUR_ASN = 27218;
define VULTR_ASN = 64515;

protocol device {
    scan time 10;
}

# Direct protocol for IPv4
protocol direct {
    ipv4;
    interface "dummy*";
}

# Direct protocol for IPv6
protocol direct v6direct {
    ipv6;
    interface "dummy*";
}

# Define IPv4 networks to announce
protocol static {
    ipv4 {
        export all;
    };
    route 192.30.120.0/23 blackhole;
}

# Define IPv6 networks to announce
protocol static v6static {
    ipv6 {
        export all;
    };
    route 2620:71:4000::/48 blackhole;
}

# BGP configuration for Vultr IPv4 with 2x path prepending
protocol bgp vultr {
    description "vultr ipv4";
    local as OUR_ASN;
    source address 66.42.113.101;
    ipv4 {
        import all;
        export filter {
            if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
                # Add our AS twice to path (2x prepend)
                bgp_path.prepend(OUR_ASN);
                bgp_path.prepend(OUR_ASN);
                accept;
            } else reject;
        };
    };
    graceful restart on;
    multihop 2;
    neighbor 169.254.169.254 as VULTR_ASN;
    password "xV72GUaFMSYxNmee";
}

# BGP configuration for Vultr IPv6 with 2x path prepending
protocol bgp vultr6 {
    description "vultr ipv6";
    local as OUR_ASN;
    ipv6 {
        import none;
        export filter {
            if proto = "v6static" then {
                # Add our AS twice to path (2x prepend)
                bgp_path.prepend(OUR_ASN);
                bgp_path.prepend(OUR_ASN);
                accept;
            } else reject;
        };
    };
    graceful restart on;
    multihop 2;
    neighbor 2001:19f0:ffff::1 as VULTR_ASN;
    password "xV72GUaFMSYxNmee";
}
EOF

# Copy configs to servers
echo "Copying dual-stack configurations to servers..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/bird_ewr_dual.conf root@66.135.18.138:/etc/bird/bird.conf
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/bird_mia_dual.conf root@149.28.108.180:/etc/bird/bird.conf
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/bird_ord_dual.conf root@66.42.113.101:/etc/bird/bird.conf

# Restart BIRD on all servers
echo "Restarting BIRD service on all servers..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@66.135.18.138 "systemctl restart bird"
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@149.28.108.180 "systemctl restart bird"
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@66.42.113.101 "systemctl restart bird"

echo "Waiting for BGP sessions to establish..."
sleep 20

# Check status on all servers
echo "Checking BGP status on all servers..."
echo "=== Primary Server (EWR) ==="
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@66.135.18.138 "birdc show protocols all vultr6"
echo
echo "=== Secondary Server (MIA) ==="
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@149.28.108.180 "birdc show protocols all vultr6"
echo
echo "=== Tertiary Server (ORD) ==="
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@66.42.113.101 "birdc show protocols all vultr6"

echo "IPv6 BGP configuration has been added to all servers."
echo "Run ./bgp_summary.sh to see the complete BGP status."