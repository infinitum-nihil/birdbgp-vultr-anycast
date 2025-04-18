#!/bin/bash
# Script to update deploy.sh with improved dual-stack BGP support
source "$(dirname "$0")/.env"

echo "Updating deploy.sh with improved dual-stack BGP configuration..."

# Create a backup of the original deploy.sh
cp deploy.sh deploy.sh.bak.$(date +%s)

# Update generate_dual_stack_bird_config function
sed -i '/# Function to generate dual-stack BIRD configuration/,/return 0/c\
# Function to generate dual-stack BIRD configuration (both IPv4 and IPv6)\
generate_dual_stack_bird_config() {\
  local server_type=$1\
  local ipv4=$2\
  local prepend_count=$3\
  local ipv6=$4\
  local config_file="${server_type}_bird.conf"\
  \
  echo "Generating dual-stack BIRD configuration for $server_type server..."\
  \
  # Use variables for ASN and BIRD version\
  local OUR_ASN="${OUR_AS:-27218}"\
  local VULTR_ASN="64515"\
  local BIRD_VERSION="2.16.2"\
  \
  # Determine prepend string based on count\
  local prepend_string=""\
  if [ "$prepend_count" -gt 0 ]; then\
    for i in $(seq 1 $prepend_count); do\
      prepend_string="${prepend_string}    bgp_path.prepend($OUR_ASN);\n"\
    done\
  fi\
  \
  # Start with basic dual-stack configuration\
  cat > "$config_file" << EOL\
# BIRD $BIRD_VERSION Configuration for $server_type Server (Dual-Stack)\
router id $ipv4;\
log syslog all;\
\
# Define our ASN and peer ASN\
define OUR_ASN = $OUR_ASN;\
define VULTR_ASN = $VULTR_ASN;\
\
# Define our prefixes\
define OUR_IPV4_PREFIX = ${OUR_IPV4_BGP_RANGE:-192.30.120.0/23};\
define OUR_IPV6_PREFIX = ${OUR_IPV6_BGP_RANGE:-2620:71:4000::/48};\
\
# Common configuration for all protocols\
protocol device { }\
\
# Direct protocol for IPv4\
protocol direct v4direct {\
  ipv4;\
  interface "dummy*", "enp1s0";\
}\
\
# Direct protocol for IPv6\
protocol direct v6direct {\
  ipv6;\
  interface "dummy*", "enp1s0";\
}\
\
# Kernel protocol for IPv4\
protocol kernel v4kernel {\
  ipv4 {\
    export all;\
  };\
}\
\
# Kernel protocol for IPv6\
protocol kernel v6kernel {\
  ipv6 {\
    export all;\
  };\
}\
\
# Static routes for IPv4\
protocol static v4static {\
  ipv4;\
  route OUR_IPV4_PREFIX blackhole;\
}\
\
# Static routes for IPv6\
protocol static v6static {\
  ipv6;\
  route OUR_IPV6_PREFIX blackhole;\
}\
\
# IPv4 BGP configuration\
protocol bgp vultr_v4 {\
  description "Vultr IPv4 BGP";\
  local as OUR_ASN;\
  neighbor 169.254.169.254 as VULTR_ASN;\
  multihop 2;\
  password "${VULTR_BGP_PASSWORD:-xV72GUaFMSYxNmee}";\
  ipv4 {\
    import none;\
EOL\
\
  # Add path prepending for IPv4 if specified\
  if [ "$prepend_count" -gt 0 ]; then\
    cat >> "$config_file" << EOL\
    export filter {\
      if proto = "v4static" then {\
        # Add path prepending ($prepend_count times)\
$(echo -e "$prepend_string")\
        accept;\
      }\
      else reject;\
    };\
EOL\
  else\
    cat >> "$config_file" << EOL\
    export where proto = "v4static";\
EOL\
  fi\
\
  # Continue with the IPv6 BGP configuration\
  cat >> "$config_file" << EOL\
  };\
}\
\
# IPv6 BGP configuration\
protocol bgp vultr_v6 {\
  description "Vultr IPv6 BGP";\
  local as OUR_ASN;\
  neighbor 2001:19f0:ffff::1 as VULTR_ASN;\
  multihop 2;\
  password "${VULTR_BGP_PASSWORD:-xV72GUaFMSYxNmee}";\
  ipv6 {\
    import none;\
EOL\
\
  # Add path prepending for IPv6 if specified\
  if [ "$prepend_count" -gt 0 ]; then\
    cat >> "$config_file" << EOL\
    export filter {\
      if proto = "v6static" then {\
        # Add path prepending ($prepend_count times)\
$(echo -e "$prepend_string")\
        accept;\
      }\
      else reject;\
    };\
EOL\
  else\
    cat >> "$config_file" << EOL\
    export where proto = "v6static";\
EOL\
  fi\
\
  # Finish the configuration\
  cat >> "$config_file" << EOL\
  };\
}\
EOL\
\
  echo "Dual-stack BIRD configuration generated at $config_file"\
  return 0\
}' deploy.sh

# Update deploy_dual_stack_bird_config function
sed -i '/# Function to deploy IPv6 BIRD configuration to a server/,/return 0/c\
# Function to deploy dual-stack BIRD configuration to a server\
deploy_dual_stack_bird_config() {\
  local server_type=$1\
  local server_ip=$2\
  local config_file="${server_type}_bird.conf"\
  \
  echo "Deploying dual-stack BIRD configuration to $server_type server at $server_ip..."\
  \
  # Check if config file exists\
  if [ ! -f "$config_file" ]; then\
    log "Error: Configuration file $config_file not found for $server_type server." "ERROR"\
    return 1\
  fi\
  \
  # Upload BIRD configuration\
  scp $SSH_OPTIONS "$config_file" "root@$server_ip:/etc/bird/bird.conf"\
  \
  # Configure server for BGP\
  ssh $SSH_OPTIONS "root@$server_ip" << 'EOL'\
# Install BIRD if not already installed\
if ! command -v bird &> /dev/null; then\
  apt-get update\
  apt-get install -y bird2 build-essential git curl wget automake flex bison libncurses-dev libreadline-dev\
fi\
\
# Create and configure dummy interface for both IPv4 and IPv6\
ip link add dummy0 type dummy || true\
ip link set dummy0 up\
\
# Create RPKI and other include directories\
mkdir -p /etc/bird/rpki\
\
# Enable and start BIRD service\
systemctl enable bird\
systemctl restart bird\
\
# Set up hourly cron job to check and restart BIRD if needed\
cat > /etc/cron.hourly/check_bird << 'CRON'\
#!/bin/bash\
if ! systemctl is-active --quiet bird; then\
  logger -t bird-cron "BIRD service not running. Attempting to restart..."\
  systemctl restart bird\
fi\
CRON\
\
chmod +x /etc/cron.hourly/check_bird\
EOL\
  \
  echo "Dual-stack BIRD configuration deployed to $server_type server"\
  return 0\
}' deploy.sh

# Update the BIRD version reference
sed -i 's/BIRD 2.0.8/BIRD 2.16.2/g' deploy.sh

# Update main deployment function to use dual-stack configuration
sed -i '/# Generate BIRD configurations/,/generate_ipv6_bird_config/c\
  # Generate BIRD configurations\
  # Use improved dual-stack configurations for all servers\
  generate_dual_stack_bird_config "ewr-ipv4-primary" "$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)" 0 ""\
  generate_dual_stack_bird_config "mia-ipv4-secondary" "$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)" 1 ""\
  generate_dual_stack_bird_config "ord-ipv4-tertiary" "$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)" 2 ""\
  generate_dual_stack_bird_config "lax-ipv6" "$(cat lax-ipv6-bgp-1c1g_ipv4.txt)" 2 "$(cat lax-ipv6-bgp-1c1g_ipv6.txt)"' deploy.sh

# Update the deployment section to use dual-stack deployment
sed -i '/# Deploy BIRD configurations/,/log "All servers now have dual-stack/c\
  # Deploy BIRD configurations with dual-stack support\
  deploy_dual_stack_bird_config "ewr-ipv4-primary" "$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)"\
  deploy_dual_stack_bird_config "mia-ipv4-secondary" "$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)"\
  deploy_dual_stack_bird_config "ord-ipv4-tertiary" "$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)"\
  deploy_dual_stack_bird_config "lax-ipv6" "$(cat lax-ipv6-bgp-1c1g_ipv4.txt)"\
  \
  log "All servers now have dual-stack BGP support where IPv6 is available" "INFO"' deploy.sh

echo "deploy.sh has been updated with improved dual-stack BGP support."
echo "Original file backed up as deploy.sh.bak.*"
echo "Use './upgrade_all_servers.sh' to upgrade BIRD and apply dual-stack configs on all servers."