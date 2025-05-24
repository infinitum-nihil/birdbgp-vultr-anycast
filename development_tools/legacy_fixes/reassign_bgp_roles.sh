#!/bin/bash
# Script to reassign BGP roles and update path prepending
# This allows changing which server is primary, secondary, tertiary, quaternary

# Source .env file to get configuration
source "$(dirname "$0")/.env"

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"

# Function to display script usage
usage() {
  echo -e "${BOLD}Usage:${RESET} $0 [OPTIONS]"
  echo ""
  echo "This script allows you to change which server acts as the primary, secondary, tertiary, or quaternary BGP speaker."
  echo "It will update the path prepending configuration accordingly on all servers."
  echo ""
  echo -e "${BOLD}OPTIONS:${RESET}"
  echo "  -p, --primary [REGION]     Set the region to be primary (no path prepending)"
  echo "  -s, --secondary [REGION]   Set the region to be secondary (1x path prepending)"
  echo "  -t, --tertiary [REGION]    Set the region to be tertiary (2x path prepending)"
  echo "  -q, --quaternary [REGION]  Set the region to be quaternary (2x path prepending)"
  echo "  -y, --yes                  Auto-confirm changes without prompting"
  echo "  -h, --help                 Show this help message"
  echo ""
  echo -e "${BOLD}EXAMPLE:${RESET}"
  echo "  $0 --primary lax --secondary ewr --tertiary mia --quaternary ord"
  echo ""
  echo -e "${BOLD}NOTE:${RESET} If you don't specify all roles, current values from .env will be used."
  echo ""
  exit 1
}

# Parse command-line arguments
PRIMARY=""
SECONDARY=""
TERTIARY=""
QUATERNARY=""
AUTO_CONFIRM=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
    -p|--primary) PRIMARY="$2"; shift ;;
    -s|--secondary) SECONDARY="$2"; shift ;;
    -t|--tertiary) TERTIARY="$2"; shift ;;
    -q|--quaternary) QUATERNARY="$2"; shift ;;
    -y|--yes) AUTO_CONFIRM=true ;;
    -h|--help) usage ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

# Check if we have at least one role specified
if [ -z "$PRIMARY" ] && [ -z "$SECONDARY" ] && [ -z "$TERTIARY" ] && [ -z "$QUATERNARY" ]; then
  echo -e "${RED}Error: You must specify at least one role to change.${RESET}"
  usage
fi

# Verify required environment variables
if [ -z "$BGP_REGION_PRIMARY" ] || [ -z "$BGP_REGION_SECONDARY" ] || [ -z "$BGP_REGION_TERTIARY" ] || [ -z "$BGP_REGION_QUATERNARY" ]; then
  echo -e "${RED}Error: BGP region variables not set in .env file.${RESET}"
  echo "Ensure BGP_REGION_PRIMARY, BGP_REGION_SECONDARY, BGP_REGION_TERTIARY, and BGP_REGION_QUATERNARY are set."
  exit 1
fi

if [ -z "$SSH_KEY_PATH" ]; then
  echo -e "${RED}Error: SSH_KEY_PATH not set in .env file.${RESET}"
  exit 1
fi

# Use current values for roles not specified
PRIMARY=${PRIMARY:-$BGP_REGION_PRIMARY}
SECONDARY=${SECONDARY:-$BGP_REGION_SECONDARY}
TERTIARY=${TERTIARY:-$BGP_REGION_TERTIARY}
QUATERNARY=${QUATERNARY:-$BGP_REGION_QUATERNARY}

# Verify regions exist in Vultr's system
# This would require an API call to Vultr to validate the regions, simplified for now

# Display current and new configuration
echo -e "${BOLD}Current BGP Hierarchy:${RESET}"
echo "Primary (0x prepend): ${BGP_REGION_PRIMARY}"
echo "Secondary (1x prepend): ${BGP_REGION_SECONDARY}"
echo "Tertiary (2x prepend): ${BGP_REGION_TERTIARY}"
echo "Quaternary (2x prepend): ${BGP_REGION_QUATERNARY}"
echo ""
echo -e "${BOLD}New BGP Hierarchy:${RESET}"
echo "Primary (0x prepend): ${PRIMARY}"
echo "Secondary (1x prepend): ${SECONDARY}"
echo "Tertiary (2x prepend): ${TERTIARY}"
echo "Quaternary (2x prepend): ${QUATERNARY}"
echo ""

# Confirmation
if [ "$AUTO_CONFIRM" != "true" ]; then
  read -p "Do you want to apply these changes? (y/n): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" && "$confirm" != "yes" && "$confirm" != "Yes" && "$confirm" != "YES" ]]; then
    echo "Operation cancelled."
    exit 0
  fi
fi

# Update .env file with new regions
echo -e "${GREEN}Updating .env file...${RESET}"
sed -i.bak "s/^BGP_REGION_PRIMARY=.*/BGP_REGION_PRIMARY=$PRIMARY/" .env
sed -i.bak "s/^BGP_REGION_SECONDARY=.*/BGP_REGION_SECONDARY=$SECONDARY/" .env
sed -i.bak "s/^BGP_REGION_TERTIARY=.*/BGP_REGION_TERTIARY=$TERTIARY/" .env
sed -i.bak "s/^BGP_REGION_QUATERNARY=.*/BGP_REGION_QUATERNARY=$QUATERNARY/" .env

# For backward compatibility, also update the legacy vars
sed -i.bak "s/^IPV4_REGION_PRIMARY=.*/IPV4_REGION_PRIMARY=$PRIMARY/" .env
sed -i.bak "s/^IPV4_REGION_SECONDARY=.*/IPV4_REGION_SECONDARY=$SECONDARY/" .env
sed -i.bak "s/^IPV4_REGION_TERTIARY=.*/IPV4_REGION_TERTIARY=$TERTIARY/" .env
sed -i.bak "s/^IPV6_REGION=.*/IPV6_REGION=$QUATERNARY/" .env

# Function to get IP for a server based on its role (old or new)
get_server_ip() {
  local region=$1
  
  # Try to find IP file based on region
  local ip_file="${region}-ipv4-bgp-primary-1c1g_ipv4.txt"
  local secondary_ip_file="${region}-ipv4-bgp-secondary-1c1g_ipv4.txt"
  local tertiary_ip_file="${region}-ipv4-bgp-tertiary-1c1g_ipv4.txt"
  local quaternary_ip_file="${region}-ipv4-bgp-quaternary-1c1g_ipv4.txt"
  local ipv6_ip_file="${region}-ipv6-bgp-1c1g_ipv4.txt"
  
  # Check multiple possible files
  if [ -f "$ip_file" ]; then
    cat "$ip_file"
  elif [ -f "$secondary_ip_file" ]; then
    cat "$secondary_ip_file"
  elif [ -f "$tertiary_ip_file" ]; then
    cat "$tertiary_ip_file"
  elif [ -f "$quaternary_ip_file" ]; then
    cat "$quaternary_ip_file"
  elif [ -f "$ipv6_ip_file" ]; then
    cat "$ipv6_ip_file"
  else
    # If no file found, use deployment_state.json
    grep -A 2 "\"region\": \"$region\"" deployment_state.json | grep "main_ip" | head -1 | awk -F'"' '{print $4}'
  fi
}

# Get IPs for all servers
OLD_PRIMARY_IP=$(get_server_ip $BGP_REGION_PRIMARY)
OLD_SECONDARY_IP=$(get_server_ip $BGP_REGION_SECONDARY)
OLD_TERTIARY_IP=$(get_server_ip $BGP_REGION_TERTIARY)
OLD_QUATERNARY_IP=$(get_server_ip $BGP_REGION_QUATERNARY)

NEW_PRIMARY_IP=$(get_server_ip $PRIMARY)
NEW_SECONDARY_IP=$(get_server_ip $SECONDARY)
NEW_TERTIARY_IP=$(get_server_ip $TERTIARY)
NEW_QUATERNARY_IP=$(get_server_ip $QUATERNARY)

# Map regions to IPs for both old and new configurations
declare -A OLD_REGION_TO_IP=(
  ["$BGP_REGION_PRIMARY"]="$OLD_PRIMARY_IP"
  ["$BGP_REGION_SECONDARY"]="$OLD_SECONDARY_IP"
  ["$BGP_REGION_TERTIARY"]="$OLD_TERTIARY_IP"
  ["$BGP_REGION_QUATERNARY"]="$OLD_QUATERNARY_IP"
)

declare -A NEW_REGION_TO_IP=(
  ["$PRIMARY"]="$NEW_PRIMARY_IP"
  ["$SECONDARY"]="$NEW_SECONDARY_IP"
  ["$TERTIARY"]="$NEW_TERTIARY_IP"
  ["$QUATERNARY"]="$NEW_QUATERNARY_IP"
)

# Map regions to their new prepend counts
declare -A REGION_TO_PREPEND=(
  ["$PRIMARY"]=0
  ["$SECONDARY"]=1
  ["$TERTIARY"]=2
  ["$QUATERNARY"]=2
)

# Find all servers that need reconfiguration
echo -e "${GREEN}Identifying servers that need reconfiguration...${RESET}"
SERVERS_TO_UPDATE=()
REGIONS_TO_UPDATE=()
PREPENDS_TO_UPDATE=()

# For each region, check if its role has changed
for region in $PRIMARY $SECONDARY $TERTIARY $QUATERNARY; do
  old_prepend=-1
  
  # Determine the old prepend count
  if [ "$region" = "$BGP_REGION_PRIMARY" ]; then
    old_prepend=0
  elif [ "$region" = "$BGP_REGION_SECONDARY" ]; then
    old_prepend=1
  elif [ "$region" = "$BGP_REGION_TERTIARY" ] || [ "$region" = "$BGP_REGION_QUATERNARY" ]; then
    old_prepend=2
  fi
  
  # If the prepend count has changed, add to the list
  if [ "$old_prepend" != "${REGION_TO_PREPEND[$region]}" ]; then
    SERVERS_TO_UPDATE+=("${NEW_REGION_TO_IP[$region]}")
    REGIONS_TO_UPDATE+=("$region")
    PREPENDS_TO_UPDATE+=("${REGION_TO_PREPEND[$region]}")
    echo "Region $region needs to be updated: ${old_prepend}x prepend → ${REGION_TO_PREPEND[$region]}x prepend"
  fi
done

# If no servers need updating, exit
if [ ${#SERVERS_TO_UPDATE[@]} -eq 0 ]; then
  echo -e "${YELLOW}No servers need reconfiguration. Exiting.${RESET}"
  exit 0
fi

# Update path prepending on each server
echo -e "${GREEN}Updating BIRD configuration on servers...${RESET}"
for i in "${!SERVERS_TO_UPDATE[@]}"; do
  SERVER_IP="${SERVERS_TO_UPDATE[$i]}"
  REGION="${REGIONS_TO_UPDATE[$i]}"
  PREPEND="${PREPENDS_TO_UPDATE[$i]}"
  
  echo -e "${GREEN}Updating ${REGION} (${SERVER_IP}) to ${PREPEND}x prepend...${RESET}"
  
  # Create BIRD configuration with appropriate prepending
  generate_bird_config() {
    local ip=$1
    local prepend_count=$2
    local temp_file="/tmp/bird_config_${REGION}.conf"
    
    # Generate prepend string
    local prepend_string=""
    local our_asn="${OUR_AS:-27218}"
    if [ "$prepend_count" -gt 0 ]; then
      for ((i=1; i<=prepend_count; i++)); do
        prepend_string="${prepend_string}    bgp_path.prepend($our_asn);\n"
      done
    fi
    
    # Create configuration file
    cat > "$temp_file" << EOF
# BIRD 2.16.2 Configuration for ${REGION} Server (Dual-Stack)
router id $ip;
log syslog all;

# Define our ASN and peer ASN
define OUR_ASN = ${OUR_AS:-27218};
define VULTR_ASN = 64515;

# Define our prefixes
define OUR_IPV4_PREFIX = ${OUR_IPV4_BGP_RANGE:-192.30.120.0/23};
define OUR_IPV6_PREFIX = ${OUR_IPV6_BGP_RANGE:-2620:71:4000::/48};

# Common configuration for all protocols
protocol device { }

# Direct protocol for IPv4
protocol direct v4direct {
  ipv4;
  interface "dummy*", "enp1s0";
}

# Direct protocol for IPv6
protocol direct v6direct {
  ipv6;
  interface "dummy*", "enp1s0";
}

# Kernel protocol for IPv4
protocol kernel v4kernel {
  ipv4 {
    export all;
  };
}

# Kernel protocol for IPv6
protocol kernel v6kernel {
  ipv6 {
    export all;
  };
}

# Static routes for IPv4
protocol static v4static {
  ipv4;
  route OUR_IPV4_PREFIX blackhole;
}

# Static routes for IPv6
protocol static v6static {
  ipv6;
  route OUR_IPV6_PREFIX blackhole;
}

# IPv4 BGP configuration
protocol bgp vultr_v4 {
  description "Vultr IPv4 BGP";
  local as OUR_ASN;
  neighbor 169.254.169.254 as VULTR_ASN;
  multihop 2;
  password "${VULTR_BGP_PASSWORD:-xV72GUaFMSYxNmee}";
  ipv4 {
    import none;
EOF

    # Add prepending for IPv4
    if [ "$prepend_count" -gt 0 ]; then
      cat >> "$temp_file" << EOF
    export filter {
      if proto = "v4static" then {
        # Add path prepending (${prepend_count}x)
$(echo -e "$prepend_string")
        accept;
      }
      else reject;
    };
EOF
    else
      cat >> "$temp_file" << EOF
    export where proto = "v4static";
EOF
    fi

    # Continue with IPv6 configuration
    cat >> "$temp_file" << EOF
  };
}

# IPv6 BGP configuration
protocol bgp vultr_v6 {
  description "Vultr IPv6 BGP";
  local as OUR_ASN;
  neighbor 2001:19f0:ffff::1 as VULTR_ASN;
  multihop 2;
  password "${VULTR_BGP_PASSWORD:-xV72GUaFMSYxNmee}";
  ipv6 {
    import none;
EOF

    # Add prepending for IPv6
    if [ "$prepend_count" -gt 0 ]; then
      cat >> "$temp_file" << EOF
    export filter {
      if proto = "v6static" then {
        # Add path prepending (${prepend_count}x)
$(echo -e "$prepend_string")
        accept;
      }
      else reject;
    };
EOF
    else
      cat >> "$temp_file" << EOF
    export where proto = "v6static";
EOF
    fi

    # Finish configuration
    cat >> "$temp_file" << EOF
  };
}
EOF

    echo "$temp_file"
  }
  
  # Generate the configuration
  CONFIG_FILE=$(generate_bird_config "$SERVER_IP" "$PREPEND")
  
  # Upload to server and restart BIRD
  echo "Uploading configuration to $SERVER_IP..."
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "$CONFIG_FILE" "root@$SERVER_IP:/etc/bird/bird.conf"
  
  echo "Restarting BIRD service on $SERVER_IP..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@$SERVER_IP" "systemctl restart bird"
  
  echo "Verifying BIRD status on $SERVER_IP..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@$SERVER_IP" "birdc show status | grep -E 'BIRD|up'"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@$SERVER_IP" "birdc show protocols | grep -E 'vultr|Name'"
  
  echo -e "${GREEN}✓ Updated ${REGION} (${SERVER_IP}) successfully${RESET}"
  echo ""
done

# Create an updated version of check_bgp_status_2.sh
echo -e "${GREEN}Creating updated check_bgp_status script...${RESET}"
cat > check_bgp_status_updated.sh << 'EOF'
#!/bin/bash
# Script to check BGP status on all instances with BIRD 2.16.2

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

echo "Getting BGP instance information..."

# Get region information from .env file
if [ -z "$BGP_REGION_PRIMARY" ] || [ -z "$BGP_REGION_SECONDARY" ] || [ -z "$BGP_REGION_TERTIARY" ] || [ -z "$BGP_REGION_QUATERNARY" ]; then
  echo "Error: One or more BGP regions are not defined in .env file"
  echo "Please ensure BGP_REGION_PRIMARY, BGP_REGION_SECONDARY, BGP_REGION_TERTIARY, and BGP_REGION_QUATERNARY are set"
  exit 1
fi

# Set the IPs based on the region information from .env
PRIMARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_PRIMARY}-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_PRIMARY}-dual-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
SECONDARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_SECONDARY}-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_SECONDARY}-dual-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
TERTIARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_TERTIARY}-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_TERTIARY}-dual-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)
QUATERNARY_IP=$(cat "$(dirname "$0")/${BGP_REGION_QUATERNARY}-ipv4-bgp-quaternary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_QUATERNARY}-dual-bgp-quaternary-1c1g_ipv4.txt" 2>/dev/null || cat "$(dirname "$0")/${BGP_REGION_QUATERNARY}-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

# Check if IPs were found
if [ -z "$PRIMARY_IP" ] || [ -z "$SECONDARY_IP" ] || [ -z "$TERTIARY_IP" ] || [ -z "$QUATERNARY_IP" ]; then
  echo "Error: Could not find all required IPs in IP files."
  echo "Found: PRIMARY(${BGP_REGION_PRIMARY})=$PRIMARY_IP, SECONDARY(${BGP_REGION_SECONDARY})=$SECONDARY_IP, TERTIARY(${BGP_REGION_TERTIARY})=$TERTIARY_IP, QUATERNARY(${BGP_REGION_QUATERNARY})=$QUATERNARY_IP"
  exit 1
fi

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"

echo -e "${BOLD}========== BGP SERVERS STATUS ==========${RESET}"
echo -e "${GREEN}Primary (${BGP_REGION_PRIMARY}, 0x prepend):${RESET} $PRIMARY_IP"
echo -e "${GREEN}Secondary (${BGP_REGION_SECONDARY}, 1x prepend):${RESET} $SECONDARY_IP"
echo -e "${GREEN}Tertiary (${BGP_REGION_TERTIARY}, 2x prepend):${RESET} $TERTIARY_IP" 
echo -e "${GREEN}Quaternary (${BGP_REGION_QUATERNARY}, 2x prepend):${RESET} $QUATERNARY_IP"
echo -e "${BOLD}========================================${RESET}"

# Function to check BIRD status on a server
check_bird_status() {
  local server_ip=$1
  local server_name=$2
  local region=$3
  local prepend=$4
  
  echo
  echo -e "${BOLD}Checking $server_name (${region}, ${prepend}x prepend) BGP status on $server_ip...${RESET}"
  echo -e "${BOLD}-----------------------------------------------${RESET}"
  
  # Check BIRD version and status
  echo -e "${BOLD}BIRD Version and Status:${RESET}"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "birdc show status | grep -E 'BIRD|up'" || {
    echo "❌ ERROR: Could not get BIRD status"
    return 1
  }
  
  # Get BGP protocol status - both IPv4 and IPv6
  echo
  echo -e "${BOLD}BGP Protocol Status:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols | grep -E 'vultr|Name'" || {
    echo "❌ ERROR: Could not get BGP protocol status"
    return 1
  }
  
  # Get IPv4 BGP details
  echo
  echo -e "${BOLD}IPv4 BGP Details:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols all vultr_v4 | head -20" || {
    echo "❌ ERROR: Could not get IPv4 BGP details"
  }
  
  # Get IPv6 BGP details (all servers now support IPv6)
  echo
  echo -e "${BOLD}IPv6 BGP Details:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols all vultr_v6 | head -20" || {
    echo "❌ ERROR: Could not get IPv6 BGP details"
  }

  # Check BGP route counts
  echo
  echo -e "${BOLD}BGP Routes:${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show route count" || {
    echo "❌ ERROR: Could not get route counts"
    return 1
  }
  
  # Check network interfaces for IP addresses
  echo
  echo -e "${BOLD}Network Interfaces (check for IP addresses):${RESET}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip addr show | grep -E 'inet |inet6' | grep -v '127.0.0.1' | grep -v '::1'" || {
    echo "❌ ERROR: Could not check network interfaces"
    return 1
  }
  
  echo
  echo -e "${GREEN}✅ $server_name (${region}, ${prepend}x prepend) BGP status check completed${RESET}"
  return 0
}

# Check each server
check_bird_status "$PRIMARY_IP" "Primary" "${BGP_REGION_PRIMARY}" "0"
check_bird_status "$SECONDARY_IP" "Secondary" "${BGP_REGION_SECONDARY}" "1"  
check_bird_status "$TERTIARY_IP" "Tertiary" "${BGP_REGION_TERTIARY}" "2"
check_bird_status "$QUATERNARY_IP" "Quaternary" "${BGP_REGION_QUATERNARY}" "2"

echo
echo -e "${GREEN}BGP status check completed for all servers${RESET}"
echo
echo "To restart BGP on any server, use: ssh root@<server_ip> systemctl restart bird"
echo "To test failover, stop BGP on the primary: ssh root@$PRIMARY_IP systemctl stop bird"
EOF

chmod +x check_bgp_status_updated.sh

echo -e "${GREEN}Done! Roles have been reassigned as follows:${RESET}"
echo "Primary (0x prepend): ${PRIMARY}"
echo "Secondary (1x prepend): ${SECONDARY}"
echo "Tertiary (2x prepend): ${TERTIARY}"
echo "Quaternary (2x prepend): ${QUATERNARY}"
echo ""
echo -e "Use ${BOLD}./check_bgp_status_updated.sh${RESET} to verify the new configuration"