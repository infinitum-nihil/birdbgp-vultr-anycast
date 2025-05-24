#!/bin/bash
# fix_wireguard_peer_config.sh - Fix WireGuard peer configuration and AllowedIPs

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_nt_infinitum-nihil_com"

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# WireGuard IPs based on geographic proximity to LA headquarters
declare -A WG_IPS=(
  ["lax"]="10.10.10.1"  # Primary - Los Angeles (HQ)
  ["ord"]="10.10.10.2"  # Secondary - Chicago (closest to LA)
  ["mia"]="10.10.10.3"  # Tertiary - Miami (farther from LA)
  ["ewr"]="10.10.10.4"  # Quaternary - Newark (farthest from LA)
)

echo -e "${BLUE}Starting WireGuard peer configuration fix...${NC}"
echo -e "${YELLOW}This script will ensure all WireGuard peers have the correct AllowedIPs.${NC}"

for server in "${!SERVER_IPS[@]}"; do
  local_ip=${SERVER_IPS[$server]}
  local_wg_ip=${WG_IPS[$server]}
  
  echo -e "${BLUE}Updating WireGuard peer configuration on $server ($local_ip)...${NC}"
  
  # Dump keys from the server
  echo -e "${YELLOW}Getting public keys from $server...${NC}"
  server_public_key=$(ssh -i "$SSH_KEY_PATH" "root@$local_ip" "cat /etc/wireguard/keys/${server}_public.key 2>/dev/null || cat /etc/wireguard/public.key 2>/dev/null")
  
  # Create a new WireGuard config with correct peer information
  echo -e "${YELLOW}Creating new WireGuard configuration for $server...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$local_ip" "
    # Create a new WireGuard config
    cat > /etc/wireguard/wg0.conf.new << EOF
[Interface]
Address = ${local_wg_ip}/24
ListenPort = 51820
PrivateKey = \$(cat /etc/wireguard/keys/${server}_private.key 2>/dev/null || cat /etc/wireguard/private.key)
EOF
    
    # Add peer configurations
    for peer in lax ord mia ewr; do
      if [ \"$server\" != \"\$peer\" ]; then
        # Determine peer WireGuard IP based on role
        case \$peer in
          lax) peer_wg_ip=\"10.10.10.1\" ;;
          ord) peer_wg_ip=\"10.10.10.2\" ;;
          mia) peer_wg_ip=\"10.10.10.3\" ;;
          ewr) peer_wg_ip=\"10.10.10.4\" ;;
        esac
        
        # Get peer details
        case \$peer in
          lax) peer_public_ip=\"149.248.2.74\" ;;
          ord) peer_public_ip=\"66.42.113.101\" ;;
          mia) peer_public_ip=\"149.28.108.180\" ;;
          ewr) peer_public_ip=\"66.135.18.138\" ;;
        esac
        
        # Get public key from remote server
        echo \"Getting public key from \$peer...\"
        peer_public_key=\$(ssh -o StrictHostKeyChecking=no -i \"$SSH_KEY_PATH\" \"root@\$peer_public_ip\" \"cat /etc/wireguard/keys/\${peer}_public.key 2>/dev/null || cat /etc/wireguard/public.key 2>/dev/null\")
        
        # Add peer configuration
        cat >> /etc/wireguard/wg0.conf.new << EOF

[Peer]
PublicKey = \$peer_public_key
AllowedIPs = \$peer_wg_ip/32
Endpoint = \$peer_public_ip:51820
PersistentKeepalive = 25
EOF
      fi
    done
    
    # Replace the old config with the new one
    mv /etc/wireguard/wg0.conf.new /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    
    # Restart WireGuard
    echo 'Restarting WireGuard...'
    systemctl restart wg-quick@wg0
    
    # Check WireGuard status
    echo 'WireGuard status:'
    wg show
  "
done

echo -e "${GREEN}WireGuard peer configuration has been fixed on all servers.${NC}"
echo -e "${YELLOW}To verify connectivity, run:${NC} bash /home/normtodd/birdbgp/check_mesh_connectivity.sh"