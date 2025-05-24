#!/bin/bash
# fix_allowed_ips.sh - Fix the AllowedIPs in WireGuard configurations

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
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# The correct WireGuard IPs for each server
declare -A CORRECT_WG_IPS=(
  ["lax"]="10.10.10.1"  # Primary - Los Angeles (HQ)
  ["ord"]="10.10.10.2"  # Secondary - Chicago (closest to LA)
  ["mia"]="10.10.10.3"  # Tertiary - Miami (farther from LA)
  ["ewr"]="10.10.10.4"  # Quaternary - Newark (farthest from LA)
)

echo -e "${BLUE}Starting to fix AllowedIPs in WireGuard configurations...${NC}"

for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Fixing WireGuard configuration on $server ($ip)...${NC}"
  
  # Use sed to fix the AllowedIPs lines in the WireGuard configuration
  for peer in "${!SERVER_IPS[@]}"; do
    if [ "$server" != "$peer" ]; then
      peer_wg_ip=${CORRECT_WG_IPS[$peer]}
      
      echo -e "${BLUE}Setting peer $peer's AllowedIPs to $peer_wg_ip/32 on server $server...${NC}"
      
      # Fix the AllowedIPs for this peer
      ssh -i "$SSH_KEY_PATH" "root@$ip" "
        # Get the peer's public key
        peer_pubkey=\$(wg show wg0 | grep -A 3 'peer:' | grep -v 'peer:' | head -1 | awk '{print \$1}')
        
        # Create a new WireGuard config
        wg_config=\$(cat /etc/wireguard/wg0.conf)
        
        # Temporarily save the config
        echo \"\$wg_config\" > /etc/wireguard/wg0.conf.bak
        
        # Update AllowedIPs for this peer to its correct WireGuard IP
        sed -i 's|AllowedIPs = .*|AllowedIPs = $peer_wg_ip/32|g' /etc/wireguard/wg0.conf
        
        # Restart WireGuard
        systemctl restart wg-quick@wg0
        
        # Check the result
        echo 'Updated WireGuard configuration:'
        cat /etc/wireguard/wg0.conf | grep -A 3 'Peer'
      "
    fi
  done
  
  # Restart BIRD as well to ensure it uses the correct configuration
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Restart BIRD
    echo 'Restarting BIRD...'
    systemctl restart bird
    
    # Check BGP session status
    echo 'BGP session status after restart:'
    birdc show protocols | grep -E 'vultr|ibgp'
  "
done

echo -e "${GREEN}Fixed AllowedIPs in WireGuard configurations.${NC}"
echo -e "${YELLOW}Now creating correct peer configs from scratch...${NC}"

# Create completely new WireGuard configurations
for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  wg_ip=${CORRECT_WG_IPS[$server]}
  
  echo -e "${YELLOW}Creating new WireGuard config for $server ($ip)...${NC}"
  
  # Create a completely new WireGuard config
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Stop WireGuard first
    systemctl stop wg-quick@wg0
    
    # Make sure we have private keys
    if [ ! -f /etc/wireguard/private.key ]; then
      wg genkey > /etc/wireguard/private.key
      chmod 600 /etc/wireguard/private.key
      wg pubkey < /etc/wireguard/private.key > /etc/wireguard/public.key
    fi
    
    # Create a completely new WireGuard config
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = $wg_ip/24
ListenPort = 51820
PrivateKey = \$(cat /etc/wireguard/private.key)
EOF
  "
done

# Now get public keys from all servers
declare -A PUBLIC_KEYS
for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  PUBLIC_KEYS[$server]=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "cat /etc/wireguard/public.key")
  echo -e "${BLUE}Got public key for $server: ${PUBLIC_KEYS[$server]:0:8}...${NC}"
done

# Now add peer configurations to each server
for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Adding peer configurations to $server ($ip)...${NC}"
  
  for peer in "${!SERVER_IPS[@]}"; do
    if [ "$server" != "$peer" ]; then
      peer_ip=${SERVER_IPS[$peer]}
      peer_wg_ip=${CORRECT_WG_IPS[$peer]}
      peer_pubkey=${PUBLIC_KEYS[$peer]}
      
      echo -e "${BLUE}Adding peer $peer ($peer_wg_ip) to $server...${NC}"
      
      ssh -i "$SSH_KEY_PATH" "root@$ip" "
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
  
  # Start WireGuard with the new config
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Set proper permissions
    chmod 600 /etc/wireguard/wg0.conf
    
    # Start WireGuard
    systemctl start wg-quick@wg0
    
    # Show the result
    echo 'WireGuard status:'
    wg show
  "
done

# Now also update the iBGP configurations
for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Updating iBGP configuration on $server...${NC}"
  
  if [ "$server" = "lax" ]; then
    # LAX is the route reflector
    ibgp_content="# iBGP Configuration (LAX as route reflector)
define rr_cluster_id = 1;

template bgp ibgp_clients {
  local as 27218;
  rr client;
  rr cluster id rr_cluster_id;
  next hop self;
  direct;
  igp table master;
  import all;
  export all;
}
"
    
    # Add client configurations
    for peer in "${!SERVER_IPS[@]}"; do
      if [ "$peer" != "lax" ]; then
        peer_wg_ip=${CORRECT_WG_IPS[$peer]}
        
        ibgp_content+="
protocol bgp ibgp_${peer} from ibgp_clients {
  neighbor $peer_wg_ip as 27218;
  description \"iBGP to ${peer}\";
}
"
      fi
    done
  else
    # Non-LAX servers are clients
    ibgp_content="# iBGP Client Configuration
protocol bgp ibgp_rr {
  local as 27218;
  neighbor ${CORRECT_WG_IPS["lax"]} as 27218;
  next hop self;
  direct;
  igp table master;
  import all;
  export all;
  description \"iBGP to Route Reflector (LAX)\";
}
"
  fi
  
  # Deploy the iBGP configuration
  echo -e "$ibgp_content" | ssh -i "$SSH_KEY_PATH" "root@$ip" "cat > /etc/bird/ibgp.conf"
  
  # Restart BIRD
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Check if the ibgp.conf is included in bird.conf
    if ! grep -q 'include \"ibgp.conf\"' /etc/bird/bird.conf; then
      echo 'include \"ibgp.conf\";' >> /etc/bird/bird.conf
    fi
    
    # Restart BIRD
    systemctl restart bird
    
    # Check BGP session status
    echo 'BGP session status after iBGP config update:'
    birdc show protocols | grep -E 'vultr|ibgp'
  "
done

echo -e "${GREEN}All WireGuard and iBGP configurations have been completely rebuilt.${NC}"
echo -e "${YELLOW}The mesh network should now be functioning correctly.${NC}"
echo -e "${YELLOW}To verify, run:${NC} bash /home/normtodd/birdbgp/check_bgp_sessions.sh"