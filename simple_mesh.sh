#!/bin/bash
# simple_mesh.sh - Simplified WireGuard mesh network setup for BGP infrastructure
# Creates a secure WireGuard mesh between BGP speakers for iBGP communication

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed
CONFIG_FILE="/home/normtodd/birdbgp/config_files/config.json"
WG_BASE_IP="10.10.10"  # WireGuard subnet base
WG_PORT="51820"        # WireGuard port

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to extract IP addresses from config.json
extract_server_data() {
  echo "Extracting server data from config.json..."
  
  # Check if jq is installed
  if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Please install jq with: sudo apt-get install -y jq"
    exit 1
  fi
  
  # Check if config file exists
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
  fi
  
  # Extract server data
  local providers=$(jq -r '.cloud_providers | keys[]' "$CONFIG_FILE")
  
  declare -A SERVER_IPS
  declare -A SERVER_ROLES
  
  for provider in $providers; do
    echo -e "${BLUE}Processing provider: $provider${NC}"
    
    # Get all regions
    local regions=$(jq -r ".cloud_providers.$provider.servers | keys[]" "$CONFIG_FILE")
    
    for region in $regions; do
      echo -e "${BLUE}Processing region: $region${NC}"
      
      # Get all locations in this region
      local locations=$(jq -r ".cloud_providers.$provider.servers.\"$region\" | keys[]" "$CONFIG_FILE")
      
      for location in $locations; do
        echo -e "${BLUE}Processing location: $location${NC}"
        
        # Extract IPv4 address
        local ipv4=$(jq -r ".cloud_providers.$provider.servers.\"$region\".\"$location\".ipv4.address" "$CONFIG_FILE")
        
        # Extract role
        local role=$(jq -r ".cloud_providers.$provider.servers.\"$region\".\"$location\".ipv4.role" "$CONFIG_FILE")
        
        if [ "$ipv4" != "null" ] && [ "$ipv4" != "" ]; then
          echo -e "${GREEN}Added server $location: $ipv4 (Role: $role)${NC}"
          SERVER_IPS["$location"]="$ipv4"
          SERVER_ROLES["$location"]="$role"
        fi
      done
    done
  done
  
  # Output the extracted data
  echo -e "${YELLOW}Extracted Server Information:${NC}"
  for server in "${!SERVER_IPS[@]}"; do
    echo -e "${GREEN}$server: ${SERVER_IPS[$server]} (Role: ${SERVER_ROLES[$server]})${NC}"
  done
  
  # Export the arrays
  export SERVER_IPS
  export SERVER_ROLES
}

# Function to validate server connectivity
validate_connectivity() {
  echo -e "${BLUE}Validating connectivity to all servers...${NC}"
  local all_reachable=true
  
  for server in "${!SERVER_IPS[@]}"; do
    local ip="${SERVER_IPS[$server]}"
    echo -e "${YELLOW}Testing connectivity to $server ($ip)...${NC}"
    
    if ping -c 1 -W 2 "$ip" &> /dev/null; then
      echo -e "${GREEN}Server $server ($ip) is reachable.${NC}"
    else
      echo -e "${RED}Error: Cannot reach server $server ($ip).${NC}"
      all_reachable=false
    fi
  done
  
  if [ "$all_reachable" = false ]; then
    echo -e "${RED}Error: Not all servers are reachable. Please check connectivity.${NC}"
    return 1
  fi
  
  echo -e "${GREEN}All servers are reachable.${NC}"
  return 0
}

# Function to set up WireGuard on a server
setup_wireguard() {
  local server=$1
  local ip=${SERVER_IPS[$server]}
  
  echo -e "${BLUE}Setting up WireGuard on $server ($ip)...${NC}"
  
  # Install WireGuard and generate keys
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "root@$ip" "
    # Fix any interrupted package operations
    dpkg --configure -a
    
    # Update package lists
    DEBIAN_FRONTEND=noninteractive apt-get update
    
    # Install required packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-wireguard.conf
    sysctl -p /etc/sysctl.d/99-wireguard.conf
    
    # Generate WireGuard keys if they don't exist
    mkdir -p /etc/wireguard
    if [ ! -f /etc/wireguard/private.key ]; then
      wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
      chmod 600 /etc/wireguard/private.key
    fi
  " || {
    echo -e "${RED}Error: Failed to set up WireGuard on $server ($ip).${NC}"
    return 1
  }
  
  echo -e "${GREEN}Successfully set up WireGuard on $server ($ip).${NC}"
  return 0
}

# Function to collect WireGuard public keys
collect_wireguard_keys() {
  echo -e "${BLUE}Collecting WireGuard public keys from all servers...${NC}"
  declare -A PUBLIC_KEYS
  
  for server in "${!SERVER_IPS[@]}"; do
    local ip=${SERVER_IPS[$server]}
    echo -e "${YELLOW}Getting public key from $server ($ip)...${NC}"
    
    local pubkey=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "cat /etc/wireguard/public.key" || echo "ERROR")
    
    if [ "$pubkey" = "ERROR" ] || [ -z "$pubkey" ]; then
      echo -e "${RED}Error: Failed to get public key from $server ($ip).${NC}"
      return 1
    fi
    
    PUBLIC_KEYS["$server"]="$pubkey"
    echo -e "${GREEN}Got public key for $server: ${PUBLIC_KEYS[$server]}${NC}"
  done
  
  # Export the public keys
  export PUBLIC_KEYS
  return 0
}

# Function to create WireGuard configuration
create_wireguard_config() {
  echo -e "${BLUE}Creating WireGuard configuration on all servers...${NC}"
  
  # Assign WireGuard IPs
  declare -A WG_IPS
  local i=1
  for server in "${!SERVER_IPS[@]}"; do
    WG_IPS["$server"]="$WG_BASE_IP.$i/24"
    i=$((i+1))
  done
  
  # Create WireGuard configuration on each server
  for server in "${!SERVER_IPS[@]}"; do
    local ip=${SERVER_IPS[$server]}
    local wg_ip=${WG_IPS[$server]}
    
    echo -e "${YELLOW}Creating WireGuard config for $server ($ip)...${NC}"
    
    local config="[Interface]\n"
    config+="Address = $wg_ip\n"
    config+="ListenPort = $WG_PORT\n"
    config+="PrivateKey = \$(cat /etc/wireguard/private.key)\n\n"
    
    # Add peers
    for peer in "${!SERVER_IPS[@]}"; do
      if [ "$peer" != "$server" ]; then
        local peer_ip=${SERVER_IPS[$peer]}
        local peer_wg_ip=${WG_IPS[$peer]}
        local peer_pubkey=${PUBLIC_KEYS[$peer]}
        
        config+="[Peer]\n"
        config+="PublicKey = $peer_pubkey\n"
        config+="AllowedIPs = ${peer_wg_ip%/*}/32\n"
        config+="Endpoint = $peer_ip:$WG_PORT\n"
        config+="PersistentKeepalive = 25\n\n"
      fi
    done
    
    # Upload configuration to server
    echo -e "$config" | ssh -i "$SSH_KEY_PATH" "root@$ip" "cat > /etc/wireguard/wg0.conf && chmod 600 /etc/wireguard/wg0.conf"
    
    # Restart WireGuard
    ssh -i "$SSH_KEY_PATH" "root@$ip" "
      systemctl stop wg-quick@wg0 2>/dev/null || true
      systemctl enable wg-quick@wg0
      systemctl start wg-quick@wg0
    " || {
      echo -e "${RED}Error: Failed to start WireGuard on $server ($ip).${NC}"
      echo -e "${YELLOW}Trying to debug the issue...${NC}"
      ssh -i "$SSH_KEY_PATH" "root@$ip" "
        echo 'WireGuard config:'
        cat /etc/wireguard/wg0.conf | grep -v PrivateKey
        echo 'WireGuard status:'
        systemctl status wg-quick@wg0 || true
      "
      return 1
    }
    
    echo -e "${GREEN}Successfully configured WireGuard on $server ($ip).${NC}"
  done
  
  return 0
}

# Function to verify WireGuard connectivity
verify_wireguard() {
  echo -e "${BLUE}Verifying WireGuard connectivity between servers...${NC}"
  
  for server in "${!SERVER_IPS[@]}"; do
    local ip=${SERVER_IPS[$server]}
    
    echo -e "${YELLOW}Checking WireGuard on $server ($ip)...${NC}"
    
    # Check if WireGuard is running
    local wg_status=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "systemctl is-active wg-quick@wg0" || echo "inactive")
    
    if [ "$wg_status" != "active" ]; then
      echo -e "${RED}Error: WireGuard is not running on $server ($ip).${NC}"
      ssh -i "$SSH_KEY_PATH" "root@$ip" "
        systemctl status wg-quick@wg0
        journalctl -xeu wg-quick@wg0.service
      "
      return 1
    fi
    
    echo -e "${GREEN}WireGuard is running on $server ($ip).${NC}"
    
    # Verify connections to other servers
    for peer in "${!SERVER_IPS[@]}"; do
      if [ "$peer" != "$server" ]; then
        local peer_wg_ip=${WG_IPS[$peer]}
        peer_wg_ip=${peer_wg_ip%/*}  # Remove CIDR notation
        
        echo -e "${YELLOW}Testing ping from $server to $peer ($peer_wg_ip)...${NC}"
        
        local ping_result=$(ssh -i "$SSH_KEY_PATH" "root@$ip" "ping -c 2 -W 2 $peer_wg_ip" || echo "failed")
        
        if echo "$ping_result" | grep -q "2 received"; then
          echo -e "${GREEN}WireGuard connection from $server to $peer is working.${NC}"
        else
          echo -e "${RED}Warning: WireGuard connection from $server to $peer may not be working.${NC}"
          echo -e "${YELLOW}Debug information:${NC}"
          ssh -i "$SSH_KEY_PATH" "root@$ip" "
            echo 'WireGuard status:'
            wg show
            echo 'Route table:'
            ip route
            echo 'Ping attempt:'
            ping -c 1 -W 2 $peer_wg_ip
          "
        fi
      fi
    done
  done
  
  return 0
}

# Main function
main() {
  echo -e "${BLUE}Starting WireGuard mesh network setup...${NC}"
  
  # Extract server data
  extract_server_data
  
  # Validate connectivity
  validate_connectivity || exit 1
  
  # Set up WireGuard on all servers
  for server in "${!SERVER_IPS[@]}"; do
    setup_wireguard "$server" || exit 1
  done
  
  # Collect WireGuard public keys
  collect_wireguard_keys || exit 1
  
  # Create WireGuard configuration
  create_wireguard_config || exit 1
  
  # Verify WireGuard connectivity
  verify_wireguard || exit 1
  
  echo -e "${GREEN}WireGuard mesh network setup completed successfully!${NC}"
  echo -e "${YELLOW}Next steps:${NC}"
  echo -e "1. Configure iBGP between the servers"
  echo -e "2. Set up a looking glass for route verification"
  echo -e "3. Implement path prepending for geographic optimization"
}

# Run the main function
main