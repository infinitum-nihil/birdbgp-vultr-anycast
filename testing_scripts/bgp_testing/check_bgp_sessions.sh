#!/bin/bash
# check_bgp_sessions.sh - A simplified script to check BGP session status

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_nt_infinitum-nihil_com"  # Using correct key for nt@infinitum-nihil.com

# Server details
declare -A SERVER_IPS=(
  ["lax"]="149.248.2.74"
  ["ewr"]="66.135.18.138"
  ["mia"]="149.28.108.180"
  ["ord"]="66.42.113.101"
)

# WireGuard IPs
declare -A WG_IPS=(
  ["lax"]="10.10.10.1"  # Primary - Los Angeles (HQ)
  ["ord"]="10.10.10.2"  # Secondary - Chicago (closest to LA)
  ["mia"]="10.10.10.3"  # Tertiary - Miami (farther from LA)
  ["ewr"]="10.10.10.4"  # Quaternary - Newark (farthest from LA)
)

echo -e "${BLUE}Checking BGP and WireGuard status on all servers...${NC}"

for server in "${!SERVER_IPS[@]}"; do
  local_ip=${SERVER_IPS[$server]}
  local_wg_ip=${WG_IPS[$server]}
  
  echo -e "${YELLOW}===============================================${NC}"
  echo -e "${GREEN}Server: $server ($local_ip / $local_wg_ip)${NC}"
  echo -e "${YELLOW}===============================================${NC}"
  
  # Check WireGuard status and BGP sessions
  ssh -i "$SSH_KEY_PATH" "root@$local_ip" "
    # Check BIRD version
    echo -e '${BLUE}BIRD Version:${NC}'
    bird --version
    
    # Check if WireGuard interface exists
    echo -e '${BLUE}WireGuard Status:${NC}'
    ip link show wg0 || echo 'WireGuard interface does not exist!'
    
    # Check WireGuard configuration
    echo
    echo -e '${BLUE}WireGuard Configuration:${NC}'
    wg show
    
    # Check BIRD status
    echo
    echo -e '${BLUE}BIRD Service Status:${NC}'
    systemctl status bird | grep Active
    
    # Check BGP protocols
    echo
    echo -e '${BLUE}BGP Protocol Status:${NC}'
    birdc show protocols | grep -E 'ibgp|vultr|Name'
    
    # Get details for each BGP session
    echo
    echo -e '${BLUE}BGP Session Details:${NC}'
    protocols=\$(birdc show protocols | grep -E 'ibgp|vultr' | awk '{print \$1}')
    for proto in \$protocols; do
      echo -e '${YELLOW}Protocol: \$proto${NC}'
      birdc show protocols all \$proto | grep -E 'Description|State|Info|Neighbor|BGP state'
      echo
    done
    
    # Check for IPv4 and IPv6 announcements
    echo
    echo -e '${BLUE}BGP Announcements:${NC}'
    echo -e '${YELLOW}IPv4 Announcements:${NC}'
    birdc show route where net ~ 192.30.120.0/23 all
    echo
    echo -e '${YELLOW}IPv6 Announcements:${NC}'
    birdc show route where net ~ 2620:71:4000::/48 all
    
    # Check routes
    echo
    echo -e '${BLUE}Route Counts:${NC}'
    birdc show route count
    
    # Check firewall for WireGuard and BGP
    echo
    echo -e '${BLUE}Firewall Rules for WireGuard and BGP:${NC}'
    ufw status | grep -E '51820|179'
    
    # Check WireGuard connectivity
    echo
    echo -e '${BLUE}WireGuard Connectivity Tests:${NC}'
    for peer in lax ord mia ewr; do
      if [ \"$server\" != \"\$peer\" ]; then
        # Determine peer WireGuard IP based on role
        case \$peer in
          lax) peer_wg_ip=\"10.10.10.1\" ;;
          ord) peer_wg_ip=\"10.10.10.2\" ;;
          mia) peer_wg_ip=\"10.10.10.3\" ;;
          ewr) peer_wg_ip=\"10.10.10.4\" ;;
        esac
        
        echo -e '${YELLOW}Pinging \$peer (\$peer_wg_ip):${NC}'
        ping -c 1 -W 1 \$peer_wg_ip || echo 'Ping failed!'
      fi
    done
  "
  
  echo
done

echo -e "${GREEN}BGP and WireGuard status check completed.${NC}"
echo -e "${YELLOW}If there are issues, consider running:${NC} bash /home/normtodd/birdbgp/fix_wireguard_peer_config.sh"