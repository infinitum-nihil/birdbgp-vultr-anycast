#!/bin/bash

# Update WireGuard configurations for dual-stack IPv4/IPv6

SSH_KEY="/home/normtodd/.ssh/id_ed25519_nt_infinitum-nihil_com"

# Server configurations
declare -A SERVERS=(
    ["lax"]="149.248.2.74"
    ["ord"]="66.42.113.101" 
    ["mia"]="149.28.108.180"
    ["ewr"]="66.135.18.138"
)

# Create dual-stack WireGuard configs
create_config() {
    local node=$1
    local config_file="/tmp/wg0_${node}.conf"
    
    case $node in
        "lax")
            cat > $config_file << 'EOF'
[Interface]
PrivateKey = uKl99vw9gJ6OWRKLnPF2hLHWVjfM4O2lw2rpTdYnwGk=
Address = 10.10.10.1/24, fd00:10:10::1/64
ListenPort = 51820

[Peer]
# ORD
PublicKey = IGDoiqUswCXmKkquOvjHg85Ch9SblGUY2/bGkzlKOzM=
Endpoint = 66.42.113.101:51820
AllowedIPs = 10.10.10.2/32, fd00:10:10::2/128

[Peer]
# MIA
PublicKey = xOlrncxW1gE3CLw7cexpr341Rakggk6smEhk4x9jPmA=
Endpoint = 149.28.108.180:51820
AllowedIPs = 10.10.10.3/32, fd00:10:10::3/128

[Peer]
# EWR
PublicKey = +t2e1LqONESzLxNnZltS6vaFidvo57j1T3Vksy9lMi0=
Endpoint = 66.135.18.138:51820
AllowedIPs = 10.10.10.4/32, fd00:10:10::4/128
EOF
            ;;
        "ord")
            cat > $config_file << 'EOF'
[Interface]
PrivateKey = mJhM4RofdMLBrvqnKEaqtJ0QAZ5Mj0xjRsKAITbJhH4=
Address = 10.10.10.2/24, fd00:10:10::2/64
ListenPort = 51820

[Peer]
# LAX
PublicKey = kGxVggzlhlF1WQ0i1azEpfZDChxE5B54zkOdxbsOw2g=
Endpoint = 149.248.2.74:51820
AllowedIPs = 10.10.10.1/32, fd00:10:10::1/128
PersistentKeepalive = 25

[Peer]
# MIA
PublicKey = xOlrncxW1gE3CLw7cexpr341Rakggk6smEhk4x9jPmA=
Endpoint = 149.28.108.180:51820
AllowedIPs = 10.10.10.3/32, fd00:10:10::3/128
PersistentKeepalive = 25

[Peer]
# EWR
PublicKey = +t2e1LqONESzLxNnZltS6vaFidvo57j1T3Vksy9lMi0=
Endpoint = 66.135.18.138:51820
AllowedIPs = 10.10.10.4/32, fd00:10:10::4/128
PersistentKeepalive = 25
EOF
            ;;
        "mia")
            cat > $config_file << 'EOF'
[Interface]
PrivateKey = KDNHB73UY2tgfzKiHPFUNg548ZgPInUjPLRIojpXxkI=
Address = 10.10.10.3/24, fd00:10:10::3/64
ListenPort = 51820

[Peer]
# LAX
PublicKey = kGxVggzlhlF1WQ0i1azEpfZDChxE5B54zkOdxbsOw2g=
Endpoint = 149.248.2.74:51820
AllowedIPs = 10.10.10.1/32, fd00:10:10::1/128
PersistentKeepalive = 25

[Peer]
# ORD
PublicKey = IGDoiqUswCXmKkquOvjHg85Ch9SblGUY2/bGkzlKOzM=
Endpoint = 66.42.113.101:51820
AllowedIPs = 10.10.10.2/32, fd00:10:10::2/128
PersistentKeepalive = 25

[Peer]
# EWR
PublicKey = +t2e1LqONESzLxNnZltS6vaFidvo57j1T3Vksy9lMi0=
Endpoint = 66.135.18.138:51820
AllowedIPs = 10.10.10.4/32, fd00:10:10::4/128
PersistentKeepalive = 25
EOF
            ;;
        "ewr")
            cat > $config_file << 'EOF'
[Interface]
PrivateKey = KI8+LiHJZpZEsVuQj7a5ZLMWfKHZBzYwY3SZ9yh9bXU=
Address = 10.10.10.4/24, fd00:10:10::4/64
ListenPort = 51820

[Peer]
# LAX
PublicKey = kGxVggzlhlF1WQ0i1azEpfZDChxE5B54zkOdxbsOw2g=
Endpoint = 149.248.2.74:51820
AllowedIPs = 10.10.10.1/32, fd00:10:10::1/128
PersistentKeepalive = 25

[Peer]
# ORD
PublicKey = IGDoiqUswCXmKkquOvjHg85Ch9SblGUY2/bGkzlKOzM=
Endpoint = 66.42.113.101:51820
AllowedIPs = 10.10.10.2/32, fd00:10:10::2/128
PersistentKeepalive = 25

[Peer]
# MIA
PublicKey = xOlrncxW1gE3CLw7cexpr341Rakggk6smEhk4x9jPmA=
Endpoint = 149.28.108.180:51820
AllowedIPs = 10.10.10.3/32, fd00:10:10::3/128
PersistentKeepalive = 25
EOF
            ;;
    esac
}

# Deploy configurations
echo "Creating dual-stack WireGuard configurations..."

for node in lax ord mia ewr; do
    echo "Creating config for $node..."
    create_config $node
done

echo "Deploying to MIA first (since it's accessible)..."
scp -i $SSH_KEY /tmp/wg0_mia.conf root@149.28.108.180:/etc/wireguard/wg0.conf
ssh -i $SSH_KEY root@149.28.108.180 "systemctl restart wg-quick@wg0"

echo "Dual-stack WireGuard configurations created and MIA updated."
echo "LAX, ORD, and EWR will need to be updated when accessible."