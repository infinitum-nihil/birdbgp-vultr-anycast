#!/bin/bash
# Vultr BGP Anycast Deployment Script
# Automates the deployment of BGP Anycast infrastructure on Vultr

set -e

# Source environment variables
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "Error: .env file not found!"
  exit 1
fi

# Check required variables
if [ -z "$VULTR_API_KEY" ] || [ -z "$OUR_AS" ] || [ -z "$OUR_IPV4_BGP_RANGE" ] || [ -z "$OUR_IPV6_BGP_RANGE" ] || [ -z "$VULTR_BGP_PASSWORD" ]; then
  echo "Error: Required environment variables are missing!"
  exit 1
fi

# Set regions and plans
REGIONS=("sjc" "ewr" "ams")
PLAN="vc2-1c-1gb"
OS_ID=387 # Ubuntu 20.04

# Function to create a Vultr instance
create_instance() {
  local region=$1
  local label=$2
  local priority=$3

  echo "Creating $label instance in $region..."
  
  response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances" \
    -H "Authorization: Bearer ${VULTR_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "{
      \"region\": \"$region\",
      \"plan\": \"$PLAN\",
      \"label\": \"$label\",
      \"os_id\": $OS_ID,
      \"enable_ipv6\": true,
      \"tags\": [\"bgp\", \"priority-$priority\"],
      \"user_data\": \"#!/bin/bash\\napt-get update && apt-get install -y bird2\"
    }")
  
  # Extract instance ID
  instance_id=$(echo $response | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ -z "$instance_id" ]; then
    echo "Failed to create instance! Response: $response"
    return 1
  fi
  
  echo "Instance created with ID: $instance_id"
  echo "$instance_id" > "${label}_id.txt"
  
  # Wait for instance to be ready
  echo "Waiting for instance to be ready..."
  while true; do
    status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    if [ "$status" == "active" ]; then
      echo "Instance is ready!"
      break
    fi
    
    echo "Instance status: $status. Waiting..."
    sleep 10
  done
  
  # Get instance IP addresses
  instance_info=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  ipv4=$(echo $instance_info | grep -o '"main_ip":"[^"]*' | cut -d'"' -f4)
  ipv6=$(echo $instance_info | grep -o '"v6_main_ip":"[^"]*' | cut -d'"' -f4)
  
  echo "Instance IPv4: $ipv4"
  echo "Instance IPv6: $ipv6"
  
  echo "$ipv4" > "${label}_ipv4.txt"
  echo "$ipv6" > "${label}_ipv6.txt"
  
  return 0
}

# Function to generate BIRD configuration
generate_bird_config() {
  local server_type=$1
  local ipv4=$2
  local ipv6=$3
  local prepend_count=$4
  local config_file="${server_type}_bird.conf"
  
  echo "Generating BIRD configuration for $server_type server..."
  
  # Start with basic configuration
  cat > "$config_file" << EOL
# Global configuration
router id $ipv4;
log syslog all;
debug protocols all;

# Define networks to announce
protocol static {
  ipv4 {
    export all;
  };
  route ${OUR_IPV4_BGP_RANGE} blackhole;
}

protocol static {
  ipv6 {
    export all;
  };
  route ${OUR_IPV6_BGP_RANGE} blackhole;
}

# BGP configuration for Vultr
protocol bgp vultr {
  local as ${OUR_AS};
  source address $ipv4;
  ipv4 {
    import none;
    export all;
EOL

  # Add path prepending if needed
  if [ $prepend_count -gt 0 ]; then
    cat >> "$config_file" << EOL
    export filter {
      # Artificially increase path length by prepending the local AS number
EOL
    
    for i in $(seq 1 $prepend_count); do
      echo "      bgp_path.prepend(${OUR_AS});" >> "$config_file"
    done
    
    cat >> "$config_file" << EOL
      accept;
    };
EOL
  fi

  # Continue with the rest of the configuration
  cat >> "$config_file" << EOL
  };
  graceful restart on;
  multihop 2;
  neighbor 169.254.169.254 as 64515;
  password "${VULTR_BGP_PASSWORD}";
}

# IPv6 BGP configuration
protocol bgp vultr6 {
  local as ${OUR_AS};
  source address $ipv6;
  ipv6 {
    import none;
    export all;
EOL

  # Add path prepending for IPv6 if needed
  if [ $prepend_count -gt 0 ]; then
    cat >> "$config_file" << EOL
    export filter {
      # Artificially increase path length by prepending the local AS number
EOL
    
    for i in $(seq 1 $prepend_count); do
      echo "      bgp_path.prepend(${OUR_AS});" >> "$config_file"
    done
    
    cat >> "$config_file" << EOL
      accept;
    };
EOL
  fi

  # Finish the configuration
  cat >> "$config_file" << EOL
  };
  graceful restart on;
  multihop 2;
  neighbor 2001:19f0:ffff::1 as 64515;
  password "${VULTR_BGP_PASSWORD}";
}
EOL

  echo "BIRD configuration generated at $config_file"
}

# Function to deploy BIRD configuration to a server
deploy_bird_config() {
  local server_type=$1
  local ipv4=$2
  local config_file="${server_type}_bird.conf"
  
  echo "Deploying BIRD configuration to $server_type server ($ipv4)..."
  
  # Wait for SSH to be available
  echo "Waiting for SSH to be available..."
  while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$ipv4 echo "SSH connection successful"; do
    echo "Retrying SSH connection..."
    sleep 10
  done
  
  # Copy BIRD configuration
  scp -o StrictHostKeyChecking=no "$config_file" root@$ipv4:/etc/bird/bird.conf
  
  # Configure network and start BIRD
  ssh -o StrictHostKeyChecking=no root@$ipv4 << EOF
    # Configure IP routes
    ip addr add ${OUR_IPV4_BGP_RANGE%%/*}.1/32 dev lo
    ip route add ${OUR_IPV4_BGP_RANGE} dev lo
    ip -6 addr add ${OUR_IPV6_BGP_RANGE%%/*}::1/128 dev lo
    ip -6 route add ${OUR_IPV6_BGP_RANGE} dev lo
    
    # Enable and start BIRD
    systemctl enable bird
    systemctl start bird
    
    # Verify BGP sessions
    echo "Checking BGP status:"
    birdc show proto all vultr
    birdc show proto all vultr6
EOF
  
  echo "BIRD configuration deployed to $server_type server"
}

# Main deployment function
deploy() {
  echo "Starting Vultr BGP Anycast deployment..."
  
  # Create instances
  create_instance "${REGIONS[0]}" "bgp-primary" "1" || exit 1
  create_instance "${REGIONS[1]}" "bgp-secondary" "2" || exit 1
  create_instance "${REGIONS[2]}" "bgp-tertiary" "3" || exit 1
  
  # Generate BIRD configurations
  generate_bird_config "primary" "$(cat bgp-primary_ipv4.txt)" "$(cat bgp-primary_ipv6.txt)" 0
  generate_bird_config "secondary" "$(cat bgp-secondary_ipv4.txt)" "$(cat bgp-secondary_ipv6.txt)" 1
  generate_bird_config "tertiary" "$(cat bgp-tertiary_ipv4.txt)" "$(cat bgp-tertiary_ipv6.txt)" 2
  
  # Deploy BIRD configurations
  deploy_bird_config "primary" "$(cat bgp-primary_ipv4.txt)"
  deploy_bird_config "secondary" "$(cat bgp-secondary_ipv4.txt)"
  deploy_bird_config "tertiary" "$(cat bgp-tertiary_ipv4.txt)"
  
  echo "Deployment complete!"
  echo "Primary server: $(cat bgp-primary_ipv4.txt)"
  echo "Secondary server: $(cat bgp-secondary_ipv4.txt)"
  echo "Tertiary server: $(cat bgp-tertiary_ipv4.txt)"
  echo ""
  echo "To test failover, SSH to the primary server and run: systemctl stop bird"
  echo "Then check that traffic is redirected to the secondary server."
}

# Monitor function
monitor() {
  echo "Monitoring BGP Anycast infrastructure..."
  
  # Get instance IDs
  if [ ! -f "bgp-primary_id.txt" ] || [ ! -f "bgp-secondary_id.txt" ] || [ ! -f "bgp-tertiary_id.txt" ]; then
    echo "Error: Instance ID files not found. Have you deployed the infrastructure?"
    exit 1
  fi
  
  primary_id=$(cat bgp-primary_id.txt)
  secondary_id=$(cat bgp-secondary_id.txt)
  tertiary_id=$(cat bgp-tertiary_id.txt)
  
  # Get instance IPs
  primary_ip=$(cat bgp-primary_ipv4.txt)
  secondary_ip=$(cat bgp-secondary_ipv4.txt)
  tertiary_ip=$(cat bgp-tertiary_ipv4.txt)
  
  # Check instance status
  echo "Checking instance status..."
  
  for id in "$primary_id" "$secondary_id" "$tertiary_id"; do
    status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    echo "Instance $id status: $status"
  done
  
  # Check BGP status on each server
  echo "Checking BGP status on primary server..."
  ssh -o StrictHostKeyChecking=no root@$primary_ip "birdc show proto all vultr"
  
  echo "Checking BGP status on secondary server..."
  ssh -o StrictHostKeyChecking=no root@$secondary_ip "birdc show proto all vultr"
  
  echo "Checking BGP status on tertiary server..."
  ssh -o StrictHostKeyChecking=no root@$tertiary_ip "birdc show proto all vultr"
  
  echo "Monitoring complete!"
}

# Parse command line arguments
case "$1" in
  deploy)
    deploy
    ;;
  monitor)
    monitor
    ;;
  *)
    echo "Usage: $0 {deploy|monitor}"
    exit 1
    ;;
esac

exit 0