#!/bin/bash
# fix_wireguard_config.sh - Fix WireGuard configurations with proper private key reading

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ord"]="66.42.113.101"
  ["mia"]="149.28.108.180"
  ["ewr"]="66.135.18.138"
)

# The correct WireGuard IPs for each server
declare -A WG_IPS=(
  ["lax"]="10.10.10.1"  # Primary - Los Angeles (HQ)
  ["ord"]="10.10.10.2"  # Secondary - Chicago (closest to LA)
  ["mia"]="10.10.10.3"  # Tertiary - Miami (farther from LA)
  ["ewr"]="10.10.10.4"  # Quaternary - Newark (farthest from LA)
)

echo -e "${BLUE}Starting to fix WireGuard configurations...${NC}"

# First get all public keys
declare -A PUBLIC_KEYS
for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Getting public key for $server ($ip)...${NC}"
  
  # Generate a new key pair if needed
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    if [ ! -f /etc/wireguard/private.key ] || [ ! -f /etc/wireguard/public.key ]; then
      echo 'Generating new WireGuard keys...'
      umask 077
      wg genkey > /etc/wireguard/private.key
      wg pubkey < /etc/wireguard/private.key > /etc/wireguard/public.key
    fi
  "
  
  # Get the public key
  PUBLIC_KEYS[$server]=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "cat /etc/wireguard/public.key")
  
  echo -e "${GREEN}Got public key for $server: ${PUBLIC_KEYS[$server]:0:8}...${NC}"
done

# Now create proper WireGuard configs
for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  wg_ip=${WG_IPS[$server]}
  
  echo -e "${YELLOW}Creating proper WireGuard config for $server ($ip)...${NC}"
  
  # First stop WireGuard if it's running
  ssh -i "$SSH_KEY_PATH" "root@$ip" "systemctl stop wg-quick@wg0 || true"
  
  # Create the interface section first
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Get the private key
    PRIVATE_KEY=\$(cat /etc/wireguard/private.key)
    
    # Create the config file with the correct interface section
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = $wg_ip/24
ListenPort = 51820
PrivateKey = \$PRIVATE_KEY
EOF
    
    # Make sure it has the right permissions
    chmod 600 /etc/wireguard/wg0.conf
  "
  
  # Now add the peer sections
  for peer in "${!SERVER_IPS[@]}"; do
    if [ "$server" != "$peer" ]; then
      peer_ip=${SERVER_IPS[$peer]}
      peer_wg_ip=${WG_IPS[$peer]}
      peer_pubkey=${PUBLIC_KEYS[$peer]}
      
      ssh -i "$SSH_KEY_PATH" "root@$ip" "
        # Add peer section
        cat >> /etc/wireguard/wg0.conf << EOF

[Peer]
PublicKey = $peer_pubkey
AllowedIPs = $peer_wg_ip/32
Endpoint = $peer_ip:51820
PersistentKeepalive = 25
EOF
      "
    fi
  done
  
  # Start WireGuard
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    echo 'Starting WireGuard...'
    systemctl start wg-quick@wg0
    
    # Check status
    echo 'WireGuard status:'
    systemctl status wg-quick@wg0 | grep Active
    
    # Show interfaces
    wg show
  "
  
  echo -e "${GREEN}Fixed WireGuard config for $server.${NC}"
done

echo -e "${GREEN}All WireGuard configurations have been fixed.${NC}"
echo -e "${YELLOW}To verify connectivity, run:${NC} bash /home/normtodd/birdbgp/check_bgp_sessions.sh"