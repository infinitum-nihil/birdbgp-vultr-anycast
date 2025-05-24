#!/bin/bash

SSH_KEY="/home/normtodd/.ssh/id_ed25519_nt_infinitum-nihil_com"

# CORRECT KEYS (verified from working configs)
LAX_PRIVATE="0AWsUq19oUnfmlAlkfAhLOLkLy2xv5Vu0s5wu5VELU8="
LAX_PUBLIC="kGxVggzlhlF1WQ0i1azEpfZDChxE5B54zkOdxbsOw2g="

ORD_PRIVATE="MPHM4EwaePZcWzSybki8B53hdCDvXtMklQg2euokvn8="
ORD_PUBLIC="IGDoiqUswCXmKkquOvjHg85Ch9SblGUY2/bGkzlKOzM="

MIA_PRIVATE="KDNHB73UY2tgfzKiHPFUNg548ZgPInUjPLRIojpXxkI="
MIA_PUBLIC="xOlrncxW1gE3CLw7cexpr341Rakggk6smEhk4x9jPmA="

EWR_PRIVATE="SPBeS4yfWGXcArsd6QX0Ia/7NL+dotBlcMHqz9Z60VU="
EWR_PUBLIC="qCYHzXTiIMzuCgAdMV7yZEEQpRD2XJlZY3PnjOCbeQM="

# Create dual-stack configs with CORRECT keys
create_lax_config() {
    cat > /tmp/wg0_lax_correct.conf << EOF
[Interface]
PrivateKey = $LAX_PRIVATE
Address = 10.10.10.1/24, fd00:10:10::1/64
ListenPort = 51820

[Peer]
# ORD
PublicKey = $ORD_PUBLIC
Endpoint = 66.42.113.101:51820
AllowedIPs = 10.10.10.2/32, fd00:10:10::2/128
PersistentKeepalive = 25

[Peer]
# MIA
PublicKey = $MIA_PUBLIC
Endpoint = 149.28.108.180:51820
AllowedIPs = 10.10.10.3/32, fd00:10:10::3/128
PersistentKeepalive = 25

[Peer]
# EWR
PublicKey = $EWR_PUBLIC
Endpoint = 66.135.18.138:51820
AllowedIPs = 10.10.10.4/32, fd00:10:10::4/128
PersistentKeepalive = 25
EOF
}

create_ord_config() {
    cat > /tmp/wg0_ord_correct.conf << EOF
[Interface]
PrivateKey = $ORD_PRIVATE
Address = 10.10.10.2/24, fd00:10:10::2/64
ListenPort = 51820

[Peer]
# LAX
PublicKey = $LAX_PUBLIC
Endpoint = 149.248.2.74:51820
AllowedIPs = 10.10.10.1/32, fd00:10:10::1/128
PersistentKeepalive = 25

[Peer]
# MIA
PublicKey = $MIA_PUBLIC
Endpoint = 149.28.108.180:51820
AllowedIPs = 10.10.10.3/32, fd00:10:10::3/128
PersistentKeepalive = 25

[Peer]
# EWR
PublicKey = $EWR_PUBLIC
Endpoint = 66.135.18.138:51820
AllowedIPs = 10.10.10.4/32, fd00:10:10::4/128
PersistentKeepalive = 25
EOF
}

create_mia_config() {
    cat > /tmp/wg0_mia_correct.conf << EOF
[Interface]
PrivateKey = $MIA_PRIVATE
Address = 10.10.10.3/24, fd00:10:10::3/64
ListenPort = 51820

[Peer]
# LAX
PublicKey = $LAX_PUBLIC
Endpoint = 149.248.2.74:51820
AllowedIPs = 10.10.10.1/32, fd00:10:10::1/128
PersistentKeepalive = 25

[Peer]
# ORD
PublicKey = $ORD_PUBLIC
Endpoint = 66.42.113.101:51820
AllowedIPs = 10.10.10.2/32, fd00:10:10::2/128
PersistentKeepalive = 25

[Peer]
# EWR
PublicKey = $EWR_PUBLIC
Endpoint = 66.135.18.138:51820
AllowedIPs = 10.10.10.4/32, fd00:10:10::4/128
PersistentKeepalive = 25
EOF
}

create_ewr_config() {
    cat > /tmp/wg0_ewr_correct.conf << EOF
[Interface]
PrivateKey = $EWR_PRIVATE
Address = 10.10.10.4/24, fd00:10:10::4/64
ListenPort = 51820

[Peer]
# LAX
PublicKey = $LAX_PUBLIC
Endpoint = 149.248.2.74:51820
AllowedIPs = 10.10.10.1/32, fd00:10:10::1/128
PersistentKeepalive = 25

[Peer]
# ORD
PublicKey = $ORD_PUBLIC
Endpoint = 66.42.113.101:51820
AllowedIPs = 10.10.10.2/32, fd00:10:10::2/128
PersistentKeepalive = 25

[Peer]
# MIA
PublicKey = $MIA_PUBLIC
Endpoint = 149.28.108.180:51820
AllowedIPs = 10.10.10.3/32, fd00:10:10::3/128
PersistentKeepalive = 25
EOF
}

echo "Creating correct dual-stack WireGuard configurations..."
create_lax_config
create_ord_config  
create_mia_config
create_ewr_config

echo "Configurations created with CORRECT private keys"
echo "Ready to deploy when nodes come back online"