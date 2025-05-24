#!/bin/bash
# fix_firewall_rules.sh - Configures firewall rules to allow BGP and WireGuard traffic

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

echo -e "${BLUE}Starting firewall configuration to allow BGP and WireGuard traffic...${NC}"

# Function to check if ufw or iptables is in use
check_firewall_type() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${YELLOW}Checking firewall type on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    if command -v ufw &> /dev/null && ufw status | grep -q 'Status: active'; then
      echo 'ufw'
    elif command -v iptables &> /dev/null; then
      echo 'iptables'
    else
      echo 'none'
    fi
  "
}

# Function to configure firewall rules for BGP and WireGuard
configure_firewall() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Configuring firewall on $server ($ip)...${NC}"
  
  # Get firewall type
  local firewall_type=$(check_firewall_type "$server")
  
  # Create a whitelist of all server IPs
  local whitelist=""
  for peer in "${!SERVER_IPS[@]}"; do
    if [ "$peer" != "$server" ]; then
      whitelist+="${SERVER_IPS[$peer]} "
    fi
  done
  
  echo -e "${YELLOW}Configuring $firewall_type firewall on $server...${NC}"
  echo -e "${YELLOW}Whitelisting: $whitelist${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Ensure required ports are open:
    # - 51820/udp for WireGuard
    # - 179/tcp for BGP
    # - ICMP for ping
    
    if [ '$firewall_type' = 'ufw' ]; then
      # UFW configuration
      
      # First ensure UFW is installed
      apt-get update
      apt-get install -y ufw
      
      # Allow WireGuard traffic
      ufw allow 51820/udp comment 'WireGuard VPN'
      
      # Allow BGP traffic
      ufw allow 179/tcp comment 'BGP'
      
      # Allow incoming traffic from wg0 interface
      ufw allow in on wg0
      
      # Allow forwarding
      sed -i 's/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw
      
      # Create whitelist rules for all peer servers
      for peer_ip in $whitelist; do
        # Allow all traffic from other BGP servers
        ufw allow from \$peer_ip comment 'BGP Peer'
        
        # Also enable traffic to this peer
        ufw allow to \$peer_ip comment 'BGP Peer'
      done
      
      # Make sure WireGuard traffic between interfaces is allowed
      echo '# Rules for WireGuard forwarding' > /etc/ufw/before.rules.wireguard
      echo '*filter' >> /etc/ufw/before.rules.wireguard
      echo ':ufw-before-forward - [0:0]' >> /etc/ufw/before.rules.wireguard
      echo '-A ufw-before-forward -i wg0 -j ACCEPT' >> /etc/ufw/before.rules.wireguard
      echo '-A ufw-before-forward -o wg0 -j ACCEPT' >> /etc/ufw/before.rules.wireguard
      echo 'COMMIT' >> /etc/ufw/before.rules.wireguard
      
      # Add the WireGuard rules to before.rules
      if ! grep -q 'Rules for WireGuard forwarding' /etc/ufw/before.rules; then
        cat /etc/ufw/before.rules.wireguard >> /etc/ufw/before.rules
      fi
      
      # Enable and reload UFW
      echo 'y' | ufw enable
      ufw reload
      
    elif [ '$firewall_type' = 'iptables' ]; then
      # iptables configuration
      
      # Allow WireGuard traffic
      iptables -A INPUT -p udp --dport 51820 -j ACCEPT
      
      # Allow BGP traffic
      iptables -A INPUT -p tcp --dport 179 -j ACCEPT
      
      # Allow forwarded traffic from WireGuard
      iptables -A FORWARD -i wg0 -j ACCEPT
      iptables -A FORWARD -o wg0 -j ACCEPT
      
      # Allow ICMP (ping)
      iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
      
      # Allow all traffic from peer servers
      for peer_ip in $whitelist; do
        iptables -A INPUT -s \$peer_ip -j ACCEPT
        iptables -A OUTPUT -d \$peer_ip -j ACCEPT
      done
      
      # Save iptables rules
      mkdir -p /etc/iptables
      iptables-save > /etc/iptables/rules.v4
      
      # Make sure the rules load on boot
      if [ -f /etc/network/if-pre-up.d/iptables ]; then
        echo '#!/bin/sh
iptables-restore < /etc/iptables/rules.v4
exit 0' > /etc/network/if-pre-up.d/iptables
        chmod +x /etc/network/if-pre-up.d/iptables
      fi
      
      # For systemd systems
      if [ -d /etc/systemd/system ]; then
        echo '[Unit]
Description=Restore iptables rules
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target' > /etc/systemd/system/iptables-restore.service
        
        systemctl enable iptables-restore.service
      fi
    else
      echo 'No active firewall detected.'
    fi
    
    # Check for CrowdSec
    if command -v cscli &> /dev/null; then
      echo 'CrowdSec detected, adding peers to whitelist...'
      
      # Add all peer IPs to CrowdSec whitelist
      for peer_ip in $whitelist; do
        cscli decisions add --ip \$peer_ip --type whitelist --reason 'BGP Peer' || true
      done
      
      # Restart CrowdSec
      systemctl restart crowdsec
    fi
    
    # Check if port 179 is open
    echo 'Checking if BGP port (179) is open...'
    nc -z -v localhost 179 || echo 'Port 179 is NOT open!'
    
    # Check WireGuard and BGP rules in firewall
    if [ '$firewall_type' = 'ufw' ]; then
      echo 'UFW rules:'
      ufw status verbose
    elif [ '$firewall_type' = 'iptables' ]; then
      echo 'iptables rules:'
      iptables -L -v
    fi
  "
  
  echo -e "${GREEN}Firewall configured on $server.${NC}"
}

# Function to restart BIRD and check if BGP sessions come up
restart_bird() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Restarting BIRD on $server ($ip)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$ip" "
    # Restart BIRD
    systemctl restart bird
    
    # Wait for BGP sessions to establish
    sleep 10
    
    # Check BGP status
    echo 'BIRD status:'
    systemctl status bird | grep Active
    
    echo 'BGP sessions:'
    birdc show protocols | grep -E 'ibgp|vultr'
    
    echo 'Connection tests:'
    for ip in 10.10.10.{1..4}; do
      if [ \"\$ip\" != \"10.10.10.$server\" ]; then
        echo \"Ping to \$ip:\"
        ping -c 1 \$ip
        
        echo \"TCP test to \$ip:179 (BGP):\"
        nc -z -v \$ip 179 || echo 'Connection failed!'
      fi
    done
  "
}

# Configure firewall on all servers
for server in "${!SERVER_IPS[@]}"; do
  configure_firewall "$server"
done

# Restart BIRD on all servers
for server in "${!SERVER_IPS[@]}"; do
  restart_bird "$server"
done

echo -e "${GREEN}Firewall configuration completed on all servers.${NC}"
echo -e "${YELLOW}To verify BGP sessions, run:${NC} bash /home/normtodd/birdbgp/check_bgp_sessions.sh"