#!/bin/bash
# recreate_wireguard.sh - Completely recreate WireGuard configurations

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

echo -e "${BLUE}Starting complete WireGuard configuration recreation...${NC}"
echo -e "${YELLOW}New WireGuard IP assignments:${NC}"
echo -e "  LAX (primary): ${WG_IPS["lax"]}"
echo -e "  ORD (secondary): ${WG_IPS["ord"]}"
echo -e "  MIA (tertiary): ${WG_IPS["mia"]}"
echo -e "  EWR (quaternary): ${WG_IPS["ewr"]}"
echo ""

# Step 1: Generate new keys on all servers
echo -e "${BLUE}Step 1: Generating new WireGuard keys on all servers...${NC}"

declare -A PUBLIC_KEYS

for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Generating keys for $server ($ip)...${NC}"
  
  # Generate new keys
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Stop WireGuard first
    systemctl stop wg-quick@wg0 || true
    
    # Generate new keys
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    chmod 600 /etc/wireguard/private.key
  "
  
  # Retrieve the public key
  PUBLIC_KEYS[$server]=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "cat /etc/wireguard/public.key")
  
  echo -e "${GREEN}Generated keys for $server. Public key: ${PUBLIC_KEYS[$server]:0:8}...${NC}"
done

# Step 2: Create new WireGuard configurations
echo -e "${BLUE}Step 2: Creating new WireGuard configurations...${NC}"

for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  wg_ip=${WG_IPS[$server]}
  
  echo -e "${YELLOW}Creating WireGuard config for $server ($ip)...${NC}"
  
  # Create the interface section
  config="[Interface]
Address = $wg_ip/24
ListenPort = 51820
PrivateKey = \$(cat /etc/wireguard/private.key)
"
  
  # Add peer sections
  for peer in "${!SERVER_IPS[@]}"; do
    if [ "$server" != "$peer" ]; then
      peer_ip=${SERVER_IPS[$peer]}
      peer_wg_ip=${WG_IPS[$peer]}
      peer_pubkey=${PUBLIC_KEYS[$peer]}
      
      config+="
[Peer]
PublicKey = $peer_pubkey
AllowedIPs = $peer_wg_ip/32
Endpoint = $peer_ip:51820
PersistentKeepalive = 25
"
    fi
  done
  
  # Deploy the configuration
  echo -e "$config" | ssh -i "$SSH_KEY_PATH" "root@$ip" "cat > /etc/wireguard/wg0.conf && chmod 600 /etc/wireguard/wg0.conf"
  
  echo -e "${GREEN}Created WireGuard config for $server.${NC}"
done

# Step 3: Start WireGuard on all servers
echo -e "${BLUE}Step 3: Starting WireGuard on all servers...${NC}"

for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Starting WireGuard on $server ($ip)...${NC}"
  
  # Start WireGuard
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Start WireGuard
    systemctl start wg-quick@wg0
    
    # Check status
    echo 'WireGuard status:'
    wg show
  "
  
  echo -e "${GREEN}Started WireGuard on $server.${NC}"
done

# Step 4: Update iBGP configurations
echo -e "${BLUE}Step 4: Updating iBGP configurations...${NC}"

for server in "${!SERVER_IPS[@]}"; do
  ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Updating iBGP configuration on $server ($ip)...${NC}"
  
  if [ "$server" = "lax" ]; then
    # LAX is the route reflector
    ibgp_content="# iBGP Configuration for mesh network
# LAX is the route reflector

define SELF_ASN = 27218;

template bgp ibgp_clients {
  local as SELF_ASN;
  rr client;
  rr cluster id 1;
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
        peer_wg_ip=${WG_IPS[$peer]}
        
        ibgp_content+="
protocol bgp ibgp_${peer} from ibgp_clients {
  neighbor $peer_wg_ip as SELF_ASN;
  description \"iBGP to ${peer}\";
}
"
      fi
    done
  else
    # Non-route-reflector configuration (client)
    ibgp_content="# iBGP Configuration for mesh network
# Client configuration pointing to LAX as route reflector

define SELF_ASN = 27218;

protocol bgp ibgp_rr {
  local as SELF_ASN;
  neighbor ${WG_IPS["lax"]} as SELF_ASN;
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
  echo -e "$ibgp_content" | ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Ensure bird directory exists
    mkdir -p /etc/bird
    
    # Write the configuration
    cat > /etc/bird/ibgp.conf
    
    # Make sure it's included in bird.conf
    if [ -f /etc/bird/bird.conf ]; then
      if ! grep -q 'include \"ibgp.conf\";' /etc/bird/bird.conf; then
        echo 'include \"ibgp.conf\";' >> /etc/bird/bird.conf
      fi
      
      # Restart BIRD if it's running
      if systemctl is-active bird &>/dev/null; then
        echo 'Restarting BIRD...'
        systemctl restart bird
        
        # Check status
        echo 'BIRD status:'
        systemctl status bird | grep Active
        
        # Check protocols
        echo 'BGP protocols:'
        birdc show protocols | grep -E 'ibgp|vultr' || echo 'No BGP protocols found or BIRD not responding'
      else
        echo 'BIRD is not running. Starting it...'
        systemctl start bird
      fi
    else
      echo 'BIRD configuration file not found. Bird is likely not installed correctly.'
    fi
  "
  
  echo -e "${GREEN}Updated iBGP configuration on $server.${NC}"
done

echo -e "${GREEN}WireGuard mesh network has been completely recreated.${NC}"
echo -e "${YELLOW}New WireGuard IP assignments:${NC}"
echo -e "  LAX (primary): ${WG_IPS["lax"]}"
echo -e "  ORD (secondary): ${WG_IPS["ord"]}"
echo -e "  MIA (tertiary): ${WG_IPS["mia"]}"
echo -e "  EWR (quaternary): ${WG_IPS["ewr"]}"
echo ""
echo -e "${YELLOW}To verify connectivity, run:${NC} bash /home/normtodd/birdbgp/check_bgp_sessions.sh"