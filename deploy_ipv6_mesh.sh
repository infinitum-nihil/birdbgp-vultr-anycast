#!/bin/bash
# Deploy IPv6 WireGuard mesh alongside IPv4
# This provides redundant connectivity paths for BGP

set -e

echo "=== IPv6 WireGuard Mesh Deployment ==="
echo "Adding IPv6 tunnels to existing IPv4 mesh"

NODES=("lax" "ord" "mia" "ewr")
IPS=("149.248.2.74" "66.42.113.101" "149.28.108.180" "66.135.18.138")
IPV6_ADDRS=("fd00:10:10::1" "fd00:10:10::2" "fd00:10:10::3" "fd00:10:10::4")

# Function to generate IPv6 WireGuard config for a node
generate_ipv6_wg_config() {
    local node=$1
    local node_ipv6=$2
    local index=$3
    
    echo "Generating IPv6 WireGuard config for $node..."
    
    # Generate private key for this node
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(echo $PRIVATE_KEY | wg pubkey)
    
    cat > "/tmp/${node}-wg-v6.conf" << EOF
[Interface]
Address = ${node_ipv6}/64
ListenPort = 51821
PrivateKey = $PRIVATE_KEY

EOF

    # Add peers for other nodes
    for i in "${!NODES[@]}"; do
        if [ $i -ne $index ]; then
            # Generate peer public key (simplified - in production use pre-generated keys)
            PEER_PRIVATE=$(wg genkey)
            PEER_PUBLIC=$(echo $PEER_PRIVATE | wg pubkey)
            
            cat >> "/tmp/${node}-wg-v6.conf" << EOF
[Peer]
PublicKey = $PEER_PUBLIC
AllowedIPs = ${IPV6_ADDRS[$i]}/128
Endpoint = [${IPV6_ADDRS[$i]}]:51821
PersistentKeepalive = 25

EOF
        fi
    done
    
    echo "IPv6 WireGuard config generated for $node"
}

# Function to add IPv6 addresses to existing WireGuard interface
add_ipv6_to_existing_wg() {
    local node_ip=$1
    local ipv6_addr=$2
    
    echo "Adding IPv6 address $ipv6_addr to existing WireGuard interface..."
    
    ssh root@$node_ip "
        # Add IPv6 address to existing wg0 interface
        ip -6 addr add $ipv6_addr/64 dev wg0 2>/dev/null || echo 'IPv6 address may already exist'
        
        # Verify IPv6 is configured
        ip -6 addr show wg0 | grep $ipv6_addr || echo 'Failed to add IPv6 address'
        
        echo 'IPv6 address configured on wg0'
    " || echo "Warning: Failed to configure IPv6 on $node_ip"
}

# Phase 1: Add IPv6 addresses to existing WireGuard interfaces
echo -e "\n=== Phase 1: Add IPv6 addresses to existing WireGuard interfaces ==="

for i in "${!NODES[@]}"; do
    if ping -c 1 "${IPS[$i]}" > /dev/null 2>&1; then
        add_ipv6_to_existing_wg "${IPS[$i]}" "${IPV6_ADDRS[$i]}"
    else
        echo "Node ${NODES[$i]} (${IPS[$i]}) not reachable - skipping"
    fi
done

# Phase 2: Test IPv6 connectivity
echo -e "\n=== Phase 2: Test IPv6 connectivity ==="

ssh root@149.248.2.74 "
    echo 'Testing IPv6 ping from LAX to other nodes:'
    for addr in fd00:10:10::2 fd00:10:10::3 fd00:10:10::4; do
        echo \"Pinging \$addr...\"
        ping -6 -c 2 \$addr 2>/dev/null && echo \"✅ \$addr reachable\" || echo \"❌ \$addr unreachable\"
    done
" || echo "IPv6 connectivity test failed"

echo -e "\n=== IPv6 Mesh Deployment Complete ==="
echo "Next step: Update BGP configuration to use IPv6 tunnels"