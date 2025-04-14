#!/bin/bash
# Vultr BGP Anycast Deployment Script
# Automates the deployment of BGP Anycast infrastructure on Vultr
# Following Vultr documentation for floating IPs and BGP
#
# Deployment Strategy:
# - All servers deployed in US region but in different locations for geographic distribution
# - Maximized geographic placement within the Americas region (East Coast, Southeast, Midwest, West Coast)
# - Reserved IPs assigned in the same region as required by Vultr
# - Using smallest instance type (1 CPU, 1GB RAM) to minimize costs while maintaining functionality
# - 3 servers for IPv4 BGP with path prepending for failover priority
# - 1 server for IPv6 BGP

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

# Set up SSH options
SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

# Check for optional SSH key path
if [ -z "$SSH_KEY_PATH" ]; then
  echo "Note: SSH_KEY_PATH environment variable not set."
  echo "If Vultr doesn't have your SSH key, you might not be able to SSH into the servers."
  echo "Consider adding SSH_KEY_PATH to your .env file."
else
  # Read the public key from the file
  if [ -f "${SSH_KEY_PATH}.pub" ]; then
    NT_SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")
    echo "Using SSH public key from ${SSH_KEY_PATH}.pub"
    SSH_OPTIONS="$SSH_OPTIONS -i $SSH_KEY_PATH"
    echo "Using SSH key file for authentication: $SSH_KEY_PATH"
  else
    echo "Warning: SSH public key file ${SSH_KEY_PATH}.pub not found."
    unset NT_SSH_PUBLIC_KEY
  fi
fi

# Set regions and plans - all in Americas region but different locations for geographic distribution
IPV4_REGIONS=("ewr" "mia" "ord") # Newark, Miami, Chicago - all in US region
IPV6_REGION="lax"  # Los Angeles - also in US region
PLAN="vc2-1c-1gb"  # Smallest plan (1 CPU, 1GB RAM) - sufficient for BGP/BIRD2
OS_ID=387 # Ubuntu 20.04

# Function to create SSH key in Vultr account
create_ssh_key_in_vultr() {
  # Check if we have a path to the SSH public key file
  if [ -z "$SSH_KEY_PATH" ]; then
    echo "No SSH key path available. Cannot create SSH key in Vultr."
    return 1
  fi
  
  # Make sure we have the public key content
  if [ -z "$NT_SSH_PUBLIC_KEY" ]; then
    if [ -f "${SSH_KEY_PATH}.pub" ]; then
      NT_SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")
      echo "Read SSH public key from ${SSH_KEY_PATH}.pub"
    else
      echo "No SSH public key found at ${SSH_KEY_PATH}.pub"
      return 1
    fi
  fi

  local key_name="birdbgp-$(date +%Y%m%d-%H%M%S)"
  echo "Creating SSH key in Vultr with name: $key_name"
  
  # Create the SSH key via Vultr API
  ssh_key_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}ssh-keys" \
    -H "Authorization: Bearer ${VULTR_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "{
      \"name\": \"$key_name\",
      \"ssh_key\": \"$NT_SSH_PUBLIC_KEY\"
    }")
  
  # Extract the SSH key ID from the response
  created_ssh_key_id=$(echo $ssh_key_response | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ -z "$created_ssh_key_id" ]; then
    echo "Failed to create SSH key in Vultr. Response: $ssh_key_response"
    return 1
  fi
  
  echo "Successfully created SSH key in Vultr with ID: $created_ssh_key_id"
  echo "$created_ssh_key_id" > "vultr_ssh_key_id.txt"
  return 0
}

# Function to create a Vultr instance
create_instance() {
  local region=$1
  local label=$2
  local priority=$3
  local ipv6_enabled=$4 # true/false

  echo "Creating $label instance in $region..."
  
  # Get SSH key ID for our deployment
  ssh_key_id=""
  
  # First check if we already created a key for this deployment
  if [ -f "vultr_ssh_key_id.txt" ]; then
    ssh_key_id=$(cat vultr_ssh_key_id.txt)
    echo "Using previously created SSH key ID: $ssh_key_id"
  else
    # Check if SSH key exists in Vultr account
    ssh_keys=$(curl -s -X GET "${VULTR_API_ENDPOINT}ssh-keys" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    # First try to find the exact key we know works (by fingerprint)
    # The fingerprint 8xsygNZkKcXV3ncVtjxkopcl7AVdc0aBhvC1WYeJVXM was observed as working
    echo "Looking for SSH key with fingerprint matching the working key..."
    ssh_key_id=$(echo $ssh_keys | grep -i "SHA256:8xsygNZkKcXV3ncVtjxkopcl7AVdc0aBhvC1WYeJVXM" | grep -o '"id":"[^"]*' | cut -d'"' -f4 | head -1)
    
    # If the specific key isn't found, look for any key with nt@infinitum-nihil.com in name
    if [ -z "$ssh_key_id" ]; then
      ssh_key_id=$(echo $ssh_keys | grep -o '"id":"[^"]*","name":"[^"]*nt@infinitum-nihil.com[^"]*' | cut -d'"' -f4 | head -1)
    fi
    
    # If still no key, try to create one
    if [ -z "$ssh_key_id" ] && [ ! -z "$NT_SSH_PUBLIC_KEY" ]; then
      echo "No matching SSH key found. Attempting to create a new SSH key in Vultr..."
      if create_ssh_key_in_vultr; then
        ssh_key_id=$(cat vultr_ssh_key_id.txt)
      fi
    fi
  fi
  
  # Check if we have a valid SSH key ID
  if [ -z "$ssh_key_id" ]; then
    echo "WARNING: No valid SSH key ID available. You won't be able to directly SSH into the VMs."
    echo "Proceeding with deployment using default SSH key management..."
    
    # Create instance without SSH key
    response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{
        \"region\": \"$region\",
        \"plan\": \"$PLAN\",
        \"label\": \"$label\",
        \"os_id\": $OS_ID,
        \"enable_ipv6\": $ipv6_enabled,
        \"tags\": [\"bgp\", \"priority-$priority\"],
        \"user_data\": \"IyEvYmluL2Jhc2gKYXB0LWdldCB1cGRhdGUgJiYgYXB0LWdldCBpbnN0YWxsIC15IGJpcmQyCg==\"
      }")
  else
    echo "Using SSH key ID: $ssh_key_id for instance deployment"
    
    # Create instance with SSH key
    response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{
        \"region\": \"$region\",
        \"plan\": \"$PLAN\",
        \"label\": \"$label\",
        \"os_id\": $OS_ID,
        \"enable_ipv6\": $ipv6_enabled,
        \"tags\": [\"bgp\", \"priority-$priority\"],
        \"sshkey_id\": [\"$ssh_key_id\"],
        \"user_data\": \"IyEvYmluL2Jhc2gKYXB0LWdldCB1cGRhdGUgJiYgYXB0LWdldCBpbnN0YWxsIC15IGJpcmQyCg==\"
      }")
  fi
  
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
  echo "Instance IPv4: $ipv4"
  echo "$ipv4" > "${label}_ipv4.txt"
  
  if [ "$ipv6_enabled" = "true" ]; then
    ipv6=$(echo $instance_info | grep -o '"v6_main_ip":"[^"]*' | cut -d'"' -f4)
    echo "Instance IPv6: $ipv6"
    echo "$ipv6" > "${label}_ipv6.txt"
  fi
  
  return 0
}

# Function to check for existing reserved IPs
check_existing_reserved_ip() {
  local region=$1
  local ip_type=$2  # v4 or v6
  local label="floating-${ip_type/v/ip}-$region"
  
  echo "Checking for existing reserved IP with label: $label in region $region..."
  
  existing_ips=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  # Debug: show response format
  echo "Reserved IPs API response format sample (truncated):"
  echo "$existing_ips" | head -n 30 | tail -n 10
  
  # Check if response is valid JSON
  if ! echo "$existing_ips" | grep -q "\"reserved_ips\""; then
    echo "Error: Invalid response from reserved-ips API"
    echo "Response: $existing_ips"
    return 1
  fi
  
  # Use jq-like parsing with grep and sed to extract matching reserved IPs
  echo "Searching for reserved IPs matching label '$label' and region '$region'..."
  
  # Extract the reserved_ips array
  reserved_ips_array=$(echo "$existing_ips" | sed -n 's/.*"reserved_ips":\[\([^]]*\)\].*/\1/p')
  
  # Process each reserved IP object
  if echo "$reserved_ips_array" | grep -q "$label"; then
    echo "Found at least one reserved IP with matching label pattern"
    
    # Extract the ID and subnet from the response
    local existing_id=""
    local existing_ip=""
    
    # Extract all reserved IP objects and process them
    echo "$existing_ips" | grep -o '{[^{]*"id":"[^"]*"[^}]*"label":"[^"]*"[^}]*}' | while read -r ip_obj; do
      # Check if this object has our label and region
      if echo "$ip_obj" | grep -q "\"label\":\"$label\"" && echo "$ip_obj" | grep -q "\"region\":\"$region\""; then
        existing_id=$(echo "$ip_obj" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
        existing_ip=$(echo "$ip_obj" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
        
        echo "Found exact match! Reserved IP: $existing_ip (ID: $existing_id)"
        
        # Save the found IP and ID to files
        echo "$existing_id" > "floating_${ip_type/v/ip}_${region}_id.txt"
        echo "$existing_ip" > "floating_${ip_type/v/ip}_${region}.txt"
        
        # Return success
        return 0
      fi
    done
  fi
  
  echo "No matching reserved IP found, will create a new one"
  return 1
}

# Function to create a floating IP
create_floating_ip() {
  local instance_id=$1
  local region=$2
  local ip_type=$3  # ipv4 or ipv6
  
  echo "Creating floating $ip_type in region $region..."
  
  # Convert ip_type to correct format for API (v4 or v6)
  local api_ip_type="v4"
  if [ "$ip_type" = "ipv6" ]; then
    api_ip_type="v6"
  fi
  
  # Check if we already have a reserved IP for this region/type
  if check_existing_reserved_ip "$region" "$api_ip_type"; then
    floating_ip_id=$(cat "floating_${ip_type}_${region}_id.txt")
    floating_ip=$(cat "floating_${ip_type}_${region}.txt")
    
    echo "Using existing floating IP: $floating_ip (ID: $floating_ip_id)"
  else
    # Create a new reserved IP
    echo "Creating new reserved IP for $ip_type in region $region..."
    response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{
        \"region\": \"$region\",
        \"ip_type\": \"$api_ip_type\",
        \"label\": \"floating-$ip_type-$region\"
      }")
    
    echo "Reserved IP creation response: $response"
    
    # Handle various response formats
    if [[ "$response" == *"error"* ]]; then
      echo "Error creating reserved IP: $response"
      return 1
    fi
    
    # Extract floating IP details - handle different response formats
    floating_ip_id=""
    floating_ip=""
    
    # Format 1: Nested in reserved_ip object
    if [[ "$response" == *'"reserved_ip":'* ]]; then
      echo "Parsing response format 1 (nested reserved_ip object)"
      # Extract the nested object
      reserved_ip_obj=$(echo "$response" | grep -o '"reserved_ip":{[^}]*}' | sed 's/"reserved_ip"://g')
      
      # Extract fields from the object
      floating_ip_id=$(echo "$reserved_ip_obj" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      floating_ip=$(echo "$reserved_ip_obj" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      
      echo "Extracted from nested object - ID: $floating_ip_id, IP: $floating_ip"
    fi
    
    # Format 2: Direct in response
    if [ -z "$floating_ip_id" ] || [ -z "$floating_ip" ]; then
      echo "Trying parse format 2 (direct response)"
      floating_ip_id=$(echo "$response" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      floating_ip=$(echo "$response" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      
      echo "Extracted direct - ID: $floating_ip_id, IP: $floating_ip"
    fi
    
    # Format 3: Alternative field names
    if [ -z "$floating_ip" ]; then
      echo "Trying parse format 3 (alternative field names)"
      floating_ip=$(echo "$response" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
      echo "Extracted alternative - IP: $floating_ip"
    fi
    
    # Final validation
    if [ -z "$floating_ip_id" ]; then
      echo "Failed to extract reserved IP ID from response!"
      echo "Raw response: $response"
      return 1
    fi
    
    if [ -z "$floating_ip" ]; then
      echo "Failed to extract reserved IP address from response!"
      echo "Raw response: $response"
      return 1
    fi
    
    # Save the IDs and IPs
    echo "$floating_ip_id" > "floating_${ip_type}_${region}_id.txt"
    echo "$floating_ip" > "floating_${ip_type}_${region}.txt"
    
    echo "Successfully created new floating IP: $floating_ip (ID: $floating_ip_id)"
  fi
  
  # Attach floating IP to instance
  echo "Attaching floating $ip_type to instance $instance_id..."
  echo "Floating IP ID: $floating_ip_id, Instance ID: $instance_id"
  
  # Check if the instance is fully provisioned and running
  echo "Verifying instance is ready for IP attachment..."
  instance_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
  
  echo "Instance status: $instance_status"
  
  # Wait for the instance to be fully ready (ok status)
  max_attempts=10
  attempt=1
  while [ "$instance_status" != "ok" ] && [ $attempt -le $max_attempts ]; do
    echo "Instance not ready (status: $instance_status). Waiting 10 seconds (attempt $attempt/$max_attempts)..."
    sleep 10
    instance_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    echo "Updated instance status: $instance_status"
    attempt=$((attempt + 1))
  done
  
  # Give additional time for services to stabilize
  echo "Waiting 10 seconds before attempting to attach reserved IP..."
  sleep 10
  
  # First check if the IP is already attached
  echo "Checking if IP is already attached to any instance..."
  current_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  current_instance=$(echo "$current_status" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4)
  
  if [ ! -z "$current_instance" ] && [ "$current_instance" = "$instance_id" ]; then
    echo "Floating IP is already attached to the correct instance $instance_id"
    return 0
  elif [ ! -z "$current_instance" ]; then
    echo "Warning: Floating IP is attached to a different instance: $current_instance"
    echo "Will attempt to detach first..."
    
    # Detach from current instance
    detach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id/detach" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    echo "Detach response: $detach_response"
    
    # Wait for detachment to complete
    echo "Waiting 15 seconds for detachment to complete..."
    sleep 15
  fi
  
  # First attempt - use the reserved-ips endpoint
  echo "Attempting to attach IP using reserved-ips/$floating_ip_id/attach endpoint..."
  attach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id/attach" \
    -H "Authorization: Bearer ${VULTR_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "{
      \"instance_id\": \"$instance_id\"
    }")
  
  echo "Attachment response: $attach_response"
  
  # Check if attachment was successful
  if [[ "$attach_response" == *"error"* ]]; then
    echo "Warning: Error attaching floating IP. Response: $attach_response"
    echo "Will try alternate API endpoint..."
    
    # Wait before trying alternate endpoint
    sleep 10
    
    # Try the alternate endpoint format
    echo "Attempting to attach IP using instances/$instance_id/reserved-ips endpoint..."
    alt_attach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances/$instance_id/reserved-ips" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{
        \"reserved_ip\": \"$floating_ip_id\"
      }")
      
    echo "Alternate attachment response: $alt_attach_response"
    
    if [[ "$alt_attach_response" == *"error"* ]]; then
      echo "Error with alternate endpoint too. Response: $alt_attach_response"
      echo "Checking current attachment status to see if it succeeded despite errors..."
      
      # Check if the IP is already attached (sometimes API returns error but it works)
      ip_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
      
      echo "Reserved IP status: $ip_status"
      
      attached_instance=$(echo "$ip_status" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4)
      if [ "$attached_instance" = "$instance_id" ]; then
        echo "IP appears to be correctly attached to instance $instance_id despite API errors!"
      else
        echo "IP attachment failed. You may need to manually attach the floating IP in the Vultr console."
        # Continue anyway, as this won't prevent the rest of the deployment
      fi
    else
      echo "Floating IP attached using alternate endpoint."
    fi
  else
    echo "Floating IP attached successfully."
  fi
  
  # Final verification
  echo "Performing final verification of IP attachment..."
  sleep 5
  final_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  final_instance=$(echo "$final_status" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4)
  
  if [ "$final_instance" = "$instance_id" ]; then
    echo "Verified: Floating IP $floating_ip is correctly attached to instance $instance_id"
    
    # According to Vultr, server must be restarted before the additional IP can be used
    echo "Restarting instance for the reserved IP to take effect (Vultr requirement)..."
    restart_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances/$instance_id/reboot" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    echo "Restart response: $restart_response"
    
    # Wait for the restart to complete
    echo "Waiting 60 seconds for instance restart to complete..."
    sleep 60
    
    # Check instance status after restart
    instance_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    echo "Instance status after restart: $instance_status"
    
    # Wait for the instance to be fully ready again if needed
    max_attempts=10
    attempt=1
    while [ "$instance_status" != "ok" ] && [ $attempt -le $max_attempts ]; do
      echo "Instance not ready after restart (status: $instance_status). Waiting 10 seconds (attempt $attempt/$max_attempts)..."
      sleep 10
      instance_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
      echo "Updated instance status: $instance_status"
      attempt=$((attempt + 1))
    done
    
    echo "IP attachment and instance restart completed successfully."
    return 0
  else
    echo "Warning: Final verification shows floating IP is not attached to expected instance."
    echo "Current status: $final_status"
    echo "Expected instance: $instance_id, Current instance: $final_instance"
    echo "Continuing deployment, but manual verification may be needed."
  fi
  
  return 0
}

# Function to generate BIRD configuration for IPv4 servers
generate_ipv4_bird_config() {
  local server_type=$1
  local ipv4=$2
  local prepend_count=$3
  local config_file="${server_type}_bird.conf"
  
  echo "Generating IPv4 BIRD configuration for $server_type server..."
  
  # Start with basic configuration
  cat > "$config_file" << EOL
# Global configuration
router id $ipv4;
log syslog all;
debug protocols all;

# RPKI Configuration
roa table rpki_table;

# Use local Routinator as primary RPKI validator
# This is configured with ARIN TAL as first priority
protocol rpki rpki_routinator {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "localhost" port 8323;  # Routinator local RTR server
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Use ARIN's validator as first external fallback 
# ARIN operates an RTR service available publicly
protocol rpki rpki_arin {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.arin.net" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Fallback to RIPE NCC's validator as second external fallback
# Using RIPE RPKI Validator 3 (rpki-validator3.ripe.net) which is the current version
protocol rpki rpki_ripe {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rpki-validator3.ripe.net" port 8323;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Add Cloudflare's RPKI validator as final fallback
protocol rpki rpki_cloudflare {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.cloudflare.com" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Enhanced RPKI validation function with route coloring (communities)
function rpki_check() {
  # Store original validation state for community tagging
  case roa_check(rpki_table, net, bgp_path.last) {
    ROA_VALID: {
      # Add community to mark route as RPKI valid
      bgp_community.add((${OUR_AS}, 1001));
      print "RPKI: Valid route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_UNKNOWN: {
      # Add community to mark route as RPKI unknown
      bgp_community.add((${OUR_AS}, 1002));
      print "RPKI: Unknown route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_INVALID: {
      # Add community to mark route as RPKI invalid before rejecting
      bgp_community.add((${OUR_AS}, 1000));
      print "RPKI: Invalid route: ", net, " ASN: ", bgp_path.last;
      reject;
    }
  }
}

# Device protocol to detect interfaces
protocol device {
  scan time 5;
}

# Direct protocol to use with dummy interface
protocol direct {
  interface "dummy*";
  ipv4;
}

# Define networks to announce
protocol static {
  ipv4 {
    export all;
  };
  route ${OUR_IPV4_BGP_RANGE} blackhole;
}

# BGP configuration for Vultr
protocol bgp vultr {
  description "vultr";
  local as ${OUR_AS};
  source address $ipv4;
  ipv4 {
    import where rpki_check();
EOL

  # Export filter with Vultr communities for path control
  if [ $prepend_count -gt 0 ]; then
    cat >> "$config_file" << EOL
    export filter {
      # Only export routes from direct and static protocols
      if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
        # Add Vultr BGP communities based on prepend count
EOL
    
    # Use Vultr-specific communities instead of manual path prepending
    if [ $prepend_count -eq 1 ]; then
      echo "        bgp_community.add((20473,6001));" >> "$config_file"
    elif [ $prepend_count -eq 2 ]; then
      echo "        bgp_community.add((20473,6002));" >> "$config_file"
    elif [ $prepend_count -eq 3 ]; then
      echo "        bgp_community.add((20473,6003));" >> "$config_file"
    fi
    
    # Add location-based communities based on server region
    if [[ "${IPV4_REGIONS[$((prepend_count-1))]}" == "ewr" ]]; then
      echo "        # Add Piscataway location community (closest to Newark)" >> "$config_file"
      echo "        bgp_community.add((20473,11));" >> "$config_file"
    elif [[ "${IPV4_REGIONS[$((prepend_count-1))]}" == "mia" ]]; then
      echo "        # Add Miami location community" >> "$config_file"
      echo "        bgp_community.add((20473,12));" >> "$config_file"
    elif [[ "${IPV4_REGIONS[$((prepend_count-1))]}" == "ord" ]]; then
      echo "        # Add Chicago location community" >> "$config_file"
      echo "        bgp_community.add((20473,13));" >> "$config_file"
    elif [[ "${IPV4_REGIONS[$((prepend_count-1))]}" == "sjc" ]]; then
      echo "        # Add San Jose location community" >> "$config_file"
      echo "        bgp_community.add((20473,18));" >> "$config_file"
    fi
    
    cat >> "$config_file" << EOL
        accept;
      } else {
        reject;
      }
    };
EOL
  else
    cat >> "$config_file" << EOL
    export filter {
      # Only export routes from direct and static protocols
      if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
        # Add appropriate Vultr BGP communities for primary server
        # Add origin customer community
        bgp_community.add((20473,4000));
        
        # Add location community for this server
EOL
    
    # Add location-based communities based on server region
    if [[ "${IPV4_REGIONS[0]}" == "ewr" ]]; then
      echo "        # Add Piscataway location community (closest to Newark)" >> "$config_file"
      echo "        bgp_community.add((20473,11));" >> "$config_file"
    elif [[ "${IPV4_REGIONS[0]}" == "mia" ]]; then
      echo "        # Add Miami location community" >> "$config_file"
      echo "        bgp_community.add((20473,12));" >> "$config_file"
    elif [[ "${IPV4_REGIONS[0]}" == "ord" ]]; then
      echo "        # Add Chicago location community" >> "$config_file"
      echo "        bgp_community.add((20473,13));" >> "$config_file"
    elif [[ "${IPV4_REGIONS[0]}" == "sjc" ]]; then
      echo "        # Add San Jose location community" >> "$config_file"
      echo "        bgp_community.add((20473,18));" >> "$config_file"
    fi
    
    cat >> "$config_file" << EOL
        accept;
      } else {
        reject;
      }
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
EOL

  echo "IPv4 BIRD configuration generated at $config_file"
}

# Function to generate BIRD configuration for IPv6 server
generate_ipv6_bird_config() {
  local server_type=$1
  local ipv4=$2
  local ipv6=$3
  local config_file="${server_type}_bird.conf"
  
  # Calculate the link-local address from the IPv6 address
  # Extract second half of IPv6 address (the part containing ff:fe)
  local ipv6_suffix=$(echo $ipv6 | sed -E 's/.*:([0-9a-f:]+)/\1/')
  local link_local="fe80::$ipv6_suffix"
  
  echo "Generating IPv6 BIRD configuration for $server_type server..."
  echo "IPv6 address: $ipv6"
  echo "Link-local address: $link_local"
  
  # Create IPv6 configuration
  cat > "$config_file" << EOL
# Global configuration
router id $ipv4;
log syslog all;
debug protocols all;

# RPKI Configuration
roa table rpki_table;

# Use local Routinator as primary RPKI validator
# This is configured with ARIN TAL as first priority
protocol rpki rpki_routinator {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "localhost" port 8323;  # Routinator local RTR server
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Use ARIN's validator as first external fallback 
# ARIN operates an RTR service available publicly
protocol rpki rpki_arin {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.arin.net" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Fallback to RIPE NCC's validator as second external fallback
# Using RIPE RPKI Validator 3 (rpki-validator3.ripe.net) which is the current version
protocol rpki rpki_ripe {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rpki-validator3.ripe.net" port 8323;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Add Cloudflare's RPKI validator as final fallback
protocol rpki rpki_cloudflare {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.cloudflare.com" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Enhanced RPKI validation function with route coloring (communities)
function rpki_check() {
  # Store original validation state for community tagging
  case roa_check(rpki_table, net, bgp_path.last) {
    ROA_VALID: {
      # Add community to mark route as RPKI valid
      bgp_community.add((${OUR_AS}, 1001));
      print "RPKI: Valid route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_UNKNOWN: {
      # Add community to mark route as RPKI unknown
      bgp_community.add((${OUR_AS}, 1002));
      print "RPKI: Unknown route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_INVALID: {
      # Add community to mark route as RPKI invalid before rejecting
      bgp_community.add((${OUR_AS}, 1000));
      print "RPKI: Invalid route: ", net, " ASN: ", bgp_path.last;
      reject;
    }
  }
}

# Device protocol to detect interfaces
protocol device {
  scan time 5;
}

# Direct protocol to use with dummy interface
protocol direct {
  interface "dummy*";
  ipv6;
}

# Define networks to announce
protocol static {
  ipv6 {
    export all;
  };
  route ${OUR_IPV6_BGP_RANGE} blackhole;
}

# Required static route to Vultr's BGP server
protocol static STATIC6 {
  ipv6;
  route 2001:19f0:ffff::1/128 via $link_local%eth0;
}

# IPv6 BGP configuration
protocol bgp vultr6 {
  description "vultr";
  local $ipv6 as ${OUR_AS};
  neighbor 2001:19f0:ffff::1 as 64515;
  multihop 2;
  password "${VULTR_BGP_PASSWORD}";
  
  ipv6 {
    import where rpki_check();
    export filter {
      if source ~ [ RTS_DEVICE ] then {
        # Add Vultr BGP communities for IPv6 routing
        
        # Add origin customer community
        bgp_community.add((20473,4000));
        
        # Add location community for this server (Los Angeles)
        bgp_community.add((20473,17));
        
        # Use large community format for IPv6 location (Americas - United States - Los Angeles)
        # Format: 20473:0:3RRRCCC1PP where RRR=region, CCC=country, PP=location
        # Using 019 for Americas, 840 for US, 17 for Los Angeles
        bgp_large_community.add((20473,0,301984017));
        
        accept;
      } else {
        reject;
      }
    };
  };
}
EOL

  echo "IPv6 BIRD configuration generated at $config_file"
}

# Function to deploy IPv4 BIRD configuration to a server
deploy_ipv4_bird_config() {
  local server_type=$1
  local ipv4=$2
  local config_file="${server_type}_bird.conf"
  local floating_ip=$3
  
  echo "Deploying IPv4 BIRD configuration to $server_type server ($ipv4)..."
  
  # Wait for SSH to be available
  echo "Waiting for SSH to be available..."
  while ! ssh $SSH_OPTIONS root@$ipv4 echo "SSH connection successful"; do
    echo "Retrying SSH connection..."
    sleep 10
  done
  
  # Install RPKI tools and Routinator
  ssh $SSH_OPTIONS root@$ipv4 << EOF
    echo "Installing RPKI tools and Routinator..."
    apt-get update
    apt-get install -y rtrlib-tools bird2-rpki-client
    
    # Install Rust and build Routinator from source with ASPA support
    apt-get install -y curl gnupg build-essential
    
    # Install Rust
    echo "Installing Rust toolchain for building Routinator with ASPA support..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    . "$HOME/.cargo/env"
    
    # Build Routinator with ASPA feature flag
    echo "Building Routinator from source with ASPA support..."
    cargo install --locked --features aspa routinator
    
    # Create symlinks to make routinator easily accessible
    ln -sf "$HOME/.cargo/bin/routinator" /usr/local/bin/routinator

    # Create enhanced Routinator configuration
    mkdir -p /etc/routinator
    cat > /etc/routinator/routinator.conf << 'RPKICONF'
# Routinator configuration file
repository-dir = "/var/lib/routinator/rpki-cache"
rtr-listen = ["127.0.0.1:8323", "[::1]:8323"]
refresh = 300
retry = 300
expire = 7200
history-size = 10
tal-dir = "/var/lib/routinator/tals"
log-level = "info"
validation-threads = 4

# Enable HTTP server for metrics and status page
http-listen = ["127.0.0.1:8080"]
# Enable ASPA validation - requires Routinator to be built with ASPA support
enable-aspa = true
# Enable other extensions when available
enable-bgpsec = true

# SLURM (Simplified Local Internet Number Resource Management) support
# Allows for local exceptions to RPKI data
slurm = "/etc/routinator/slurm.json"
RPKICONF

    # Create a basic SLURM file for local exceptions
    cat > /etc/routinator/slurm.json << 'SLURM'
{
  "slurmVersion": 1,
  "validationOutputFilters": {
    "prefixFilters": [],
    "bgpsecFilters": []
  },
  "locallyAddedAssertions": {
    "prefixAssertions": [],
    "bgpsecAssertions": []
  }
}
SLURM

    # Create a permissions for Routinator
    chown -R routinator:routinator /etc/routinator

    # Copy the provided ARIN TAL to the Routinator TAL directory
    mkdir -p /var/lib/routinator/tals
    cp /home/normtodd/birdbgp/arin.tal /var/lib/routinator/tals/
    chown -R routinator:routinator /var/lib/routinator
    
    # Initialize Routinator - won't prompt for ARIN RPA as we provided the TAL directly
    routinator init
    
    # Create a complete systemd service file for Routinator with ASPA support
    cat > /etc/systemd/system/routinator.service << 'SYSTEMD'
[Unit]
Description=Routinator RPKI Validator with ASPA support
After=network.target

[Service]
Type=simple
User=routinator
Group=routinator
ExecStart=/usr/local/bin/routinator server --enable-aspa --config /etc/routinator/routinator.conf
Restart=on-failure
RestartSec=5
TimeoutStopSec=60

# Resource limits
MemoryHigh=512M
MemoryMax=1G
TasksMax=100

# Security hardening
ProtectSystem=full
PrivateTmp=true
ProtectHome=true
ProtectControlGroups=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SYSTEMD

    # Create routinator user if it doesn't exist
    if ! id -u routinator > /dev/null 2>&1; then
        useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/routinator --comment "Routinator RPKI Validator" routinator
    fi

    # Set proper permissions
    mkdir -p /var/lib/routinator
    chown -R routinator:routinator /var/lib/routinator
    chown -R routinator:routinator /etc/routinator

    # Reload systemd and start Routinator
    systemctl daemon-reload
    systemctl enable --now routinator
    
    # Wait for Routinator to complete initial sync
    echo "Waiting for Routinator to sync (30 seconds)..."
    sleep 30
EOF
  
  # Copy BIRD configuration
  scp $SSH_OPTIONS "$config_file" root@$ipv4:/etc/bird/bird.conf
  
  # Configure network, security, and start BIRD
  ssh $SSH_OPTIONS root@$ipv4 << EOF
    # Create dummy interface
    echo "Creating dummy interface..."
    ip link add dummy1 type dummy || true
    ip link set dummy1 up
    
    # Configure IP routes
    # Extract the network part without the CIDR suffix, then append .1
    ip_network=$(echo ${OUR_IPV4_BGP_RANGE} | cut -d'/' -f1)
    echo "Setting up dummy interface with IP: ${ip_network}.1/32"
    ip addr add ${ip_network}.1/32 dev dummy1
    ip route add local ${OUR_IPV4_BGP_RANGE} dev lo
    
    # If floating IP is provided, configure it
    if [ ! -z "$floating_ip" ]; then
      echo "Configuring floating IP: $floating_ip"
      ip addr add $floating_ip/32 dev lo
    fi
    
    # ===== SECURITY SETUP =====
    echo "Configuring security measures..."
    
    # Add SSH key for nt@infinitum-nihil.com if provided
    if [ ! -z "$NT_SSH_PUBLIC_KEY" ]; then
      echo "Adding SSH public key for nt@infinitum-nihil.com..."
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh
      echo "$NT_SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      echo "SSH key added successfully."
    fi
    
    # Install dependencies
    apt-get update
    apt-get install -y iptables-persistent fail2ban ipset unattended-upgrades
    
    # Configure unattended upgrades for security patches
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'APTCONF'
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APTCONF

    # Enable unattended upgrades
    echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    
    # Install and configure CrowdSec
    echo "Installing CrowdSec..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    apt-get install -y crowdsec
    
    # Configure CrowdSec with BGP-specific collections
    cscli collections install crowdsecurity/linux
    cscli collections install crowdsecurity/sshd
    
    # Add BGP/BIRD specific config for CrowdSec
    cat > /etc/crowdsec/acquis.d/bird.yaml << 'CROWDYAML'
filenames:
  - /var/log/syslog
labels:
  type: syslog
---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
CROWDYAML
    
    # Configure CrowdSec firewall bouncer
    apt-get install -y crowdsec-firewall-bouncer-iptables
    systemctl enable crowdsec-firewall-bouncer --now
    systemctl restart crowdsec
    
    # Setup base iptables rules
    echo "Configuring iptables firewall rules..."
    
    # Create ipset for allowed IPs
    ipset create bgp-allowed-ips hash:ip -exist
    ipset add bgp-allowed-ips 169.254.169.254 # Vultr BGP server
    
    # Flush existing rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    
    # Set default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    
    # Allow SSH (rate limited)
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
    
    # Allow BGP from Vultr
    iptables -A INPUT -p tcp --dport 179 -m set --match-set bgp-allowed-ips src -j ACCEPT
    
    # Allow RPKI validators (RTR protocol)
    iptables -A INPUT -p tcp --dport 323 -m set --match-set bgp-allowed-ips src -j ACCEPT
    
    # Allow all ICMP for ping/traceroute functionality
    iptables -A INPUT -p icmp -j ACCEPT
    
    # Allow UDP for services (DNS, etc.)
    iptables -A INPUT -p udp --dport 53 -j ACCEPT
    
    # Log denied packets
    iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables denied: " --log-level 7
    
    # Save iptables rules
    iptables-save > /etc/iptables/rules.v4
    
    # Configure sysctl for security
    cat > /etc/sysctl.d/99-security.conf << 'SYSCTL'
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Increase system file descriptor limit
fs.file-max = 65535
SYSCTL
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-security.conf
    
    # Secure SSH access
    cat > /etc/ssh/sshd_config.d/secure_ssh.conf << 'SSHCONF'
PermitRootLogin prohibit-password
PasswordAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 20
MaxSessions 2
SSHCONF
    
    # Restart SSH service
    systemctl restart sshd
    echo "Security measures configured successfully."
    # ===== END SECURITY SETUP =====
    
    # Enable and start BIRD
    systemctl enable bird
    systemctl start bird
    
    # Verify BGP sessions
    echo "Checking BGP status:"
    birdc show proto all vultr
    
    # Check RPKI status
    echo "Checking RPKI status:"
    sleep 30  # Give RPKI time to connect
    echo "Routinator status:"
    birdc show protocols rpki_routinator
    echo "ARIN validator status:" 
    birdc show protocols rpki_arin
    echo "RIPE validator status:"
    birdc show protocols rpki_ripe
    echo "Cloudflare validator status:"
    birdc show protocols rpki_cloudflare
    
    # Check Routinator service
    echo "Routinator service status:"
    systemctl status routinator
    
    # Check security services
    echo "CrowdSec status:"
    systemctl status crowdsec
    echo "Fail2ban status:"
    systemctl status fail2ban
EOF
  
  echo "IPv4 BIRD configuration deployed to $server_type server"
}

# Function to deploy IPv6 BIRD configuration to a server
deploy_ipv6_bird_config() {
  local server_type=$1
  local ipv4=$2
  local config_file="${server_type}_bird.conf"
  local floating_ipv6=$3
  
  echo "Deploying IPv6 BIRD configuration to $server_type server ($ipv4)..."
  
  # Wait for SSH to be available
  echo "Waiting for SSH to be available..."
  while ! ssh $SSH_OPTIONS root@$ipv4 echo "SSH connection successful"; do
    echo "Retrying SSH connection..."
    sleep 10
  done
  
  # Install RPKI tools and Routinator
  ssh $SSH_OPTIONS root@$ipv4 << EOF
    echo "Installing RPKI tools and Routinator..."
    apt-get update
    apt-get install -y rtrlib-tools bird2-rpki-client
    
    # Install Rust and build Routinator from source with ASPA support
    apt-get install -y curl gnupg build-essential
    
    # Install Rust
    echo "Installing Rust toolchain for building Routinator with ASPA support..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    . "$HOME/.cargo/env"
    
    # Build Routinator with ASPA feature flag
    echo "Building Routinator from source with ASPA support..."
    cargo install --locked --features aspa routinator
    
    # Create symlinks to make routinator easily accessible
    ln -sf "$HOME/.cargo/bin/routinator" /usr/local/bin/routinator

    # Create enhanced Routinator configuration
    mkdir -p /etc/routinator
    cat > /etc/routinator/routinator.conf << 'RPKICONF'
# Routinator configuration file
repository-dir = "/var/lib/routinator/rpki-cache"
rtr-listen = ["127.0.0.1:8323", "[::1]:8323"]
refresh = 300
retry = 300
expire = 7200
history-size = 10
tal-dir = "/var/lib/routinator/tals"
log-level = "info"
validation-threads = 4

# Enable HTTP server for metrics and status page
http-listen = ["127.0.0.1:8080"]
# Enable ASPA validation - requires Routinator to be built with ASPA support
enable-aspa = true
# Enable other extensions when available
enable-bgpsec = true

# SLURM (Simplified Local Internet Number Resource Management) support
# Allows for local exceptions to RPKI data
slurm = "/etc/routinator/slurm.json"
RPKICONF

    # Create a basic SLURM file for local exceptions
    cat > /etc/routinator/slurm.json << 'SLURM'
{
  "slurmVersion": 1,
  "validationOutputFilters": {
    "prefixFilters": [],
    "bgpsecFilters": []
  },
  "locallyAddedAssertions": {
    "prefixAssertions": [],
    "bgpsecAssertions": []
  }
}
SLURM

    # Create a permissions for Routinator
    chown -R routinator:routinator /etc/routinator

    # Copy the provided ARIN TAL to the Routinator TAL directory
    mkdir -p /var/lib/routinator/tals
    cp /home/normtodd/birdbgp/arin.tal /var/lib/routinator/tals/
    chown -R routinator:routinator /var/lib/routinator
    
    # Initialize Routinator - won't prompt for ARIN RPA as we provided the TAL directly
    routinator init
    
    # Create a complete systemd service file for Routinator with ASPA support
    cat > /etc/systemd/system/routinator.service << 'SYSTEMD'
[Unit]
Description=Routinator RPKI Validator with ASPA support
After=network.target

[Service]
Type=simple
User=routinator
Group=routinator
ExecStart=/usr/local/bin/routinator server --enable-aspa --config /etc/routinator/routinator.conf
Restart=on-failure
RestartSec=5
TimeoutStopSec=60

# Resource limits
MemoryHigh=512M
MemoryMax=1G
TasksMax=100

# Security hardening
ProtectSystem=full
PrivateTmp=true
ProtectHome=true
ProtectControlGroups=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SYSTEMD

    # Create routinator user if it doesn't exist
    if ! id -u routinator > /dev/null 2>&1; then
        useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/routinator --comment "Routinator RPKI Validator" routinator
    fi

    # Set proper permissions
    mkdir -p /var/lib/routinator
    chown -R routinator:routinator /var/lib/routinator
    chown -R routinator:routinator /etc/routinator

    # Reload systemd and start Routinator
    systemctl daemon-reload
    systemctl enable --now routinator
    
    # Wait for Routinator to complete initial sync
    echo "Waiting for Routinator to sync (30 seconds)..."
    sleep 30
EOF
  
  # Copy BIRD configuration
  scp $SSH_OPTIONS "$config_file" root@$ipv4:/etc/bird/bird.conf
  
  # Calculate the link-local address from the IPv6
  local ipv6_suffix=$(echo $ipv6 | sed -E 's/.*:([0-9a-f:]+)/\1/')
  local link_local="fe80::$ipv6_suffix"
  
  # Configure network, security, and start BIRD
  ssh $SSH_OPTIONS root@$ipv4 << EOF
    # Create dummy interface if not exists
    echo "Creating dummy interface..."
    ip link add dummy1 type dummy || true
    ip link set dummy1 up
    
    # Configure IPv6 routes
    ip -6 addr add ${OUR_IPV6_BGP_RANGE%%/*}::1/128 dev dummy1
    ip -6 route add local ${OUR_IPV6_BGP_RANGE} dev lo
    
    # Add static route to Vultr's BGP server via link-local
    echo "Adding static route to Vultr's BGP server..."
    ip -6 route add 2001:19f0:ffff::1/128 via $link_local dev eth0 src $ipv6
    
    # If floating IPv6 is provided, configure it
    if [ ! -z "$floating_ipv6" ]; then
      echo "Configuring floating IPv6: $floating_ipv6"
      ip -6 addr add $floating_ipv6/128 dev lo
    fi
    
    # ===== SECURITY SETUP =====
    echo "Configuring security measures..."
    
    # Add SSH key for nt@infinitum-nihil.com if provided
    if [ ! -z "$NT_SSH_PUBLIC_KEY" ]; then
      echo "Adding SSH public key for nt@infinitum-nihil.com..."
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh
      echo "$NT_SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      echo "SSH key added successfully."
    fi
    
    # Install dependencies
    apt-get update
    apt-get install -y iptables-persistent fail2ban ipset unattended-upgrades
    
    # Configure unattended upgrades for security patches
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'APTCONF'
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APTCONF

    # Enable unattended upgrades
    echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    
    # Install and configure CrowdSec
    echo "Installing CrowdSec..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    apt-get install -y crowdsec
    
    # Configure CrowdSec with BGP-specific collections
    cscli collections install crowdsecurity/linux
    cscli collections install crowdsecurity/sshd
    
    # Add BGP/BIRD specific config for CrowdSec
    cat > /etc/crowdsec/acquis.d/bird.yaml << 'CROWDYAML'
filenames:
  - /var/log/syslog
labels:
  type: syslog
---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
CROWDYAML
    
    # Configure CrowdSec firewall bouncer
    apt-get install -y crowdsec-firewall-bouncer-iptables
    systemctl enable crowdsec-firewall-bouncer --now
    systemctl restart crowdsec
    
    # Setup base iptables rules
    echo "Configuring iptables and ip6tables firewall rules..."
    
    # Create ipset for allowed IPs (IPv4)
    ipset create bgp-allowed-ips hash:ip -exist
    ipset add bgp-allowed-ips 169.254.169.254 # Vultr BGP server
    
    # Flush existing IPv4 rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    
    # Set default policies for IPv4
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    
    # Allow SSH (rate limited)
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
    
    # Allow BGP from Vultr
    iptables -A INPUT -p tcp --dport 179 -m set --match-set bgp-allowed-ips src -j ACCEPT
    
    # Allow RPKI validators (RTR protocol)
    iptables -A INPUT -p tcp --dport 323 -m set --match-set bgp-allowed-ips src -j ACCEPT
    
    # Allow all ICMP for ping/traceroute functionality
    iptables -A INPUT -p icmp -j ACCEPT
    
    # Allow UDP for services (DNS, etc.)
    iptables -A INPUT -p udp --dport 53 -j ACCEPT
    
    # Log denied packets
    iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables denied: " --log-level 7
    
    # IPv6 Firewall Configuration
    # Flush existing IPv6 rules
    ip6tables -F
    ip6tables -X
    ip6tables -t mangle -F
    ip6tables -t mangle -X
    
    # Set default policies for IPv6
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT ACCEPT
    
    # Allow established connections
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    ip6tables -A INPUT -i lo -j ACCEPT
    
    # Allow SSH (rate limited)
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
    
    # Allow BGP from Vultr IPv6 (2001:19f0:ffff::1)
    ip6tables -A INPUT -p tcp --dport 179 -s 2001:19f0:ffff::1/128 -j ACCEPT
    
    # Allow RPKI validators over IPv6
    ip6tables -A INPUT -p tcp --dport 323 -j ACCEPT
    
    # Allow all ICMPv6 which is required for proper IPv6 operation
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
    
    # Allow UDP for services (DNS, etc.)
    ip6tables -A INPUT -p udp --dport 53 -j ACCEPT
    
    # Allow DHCPv6 client
    ip6tables -A INPUT -p udp --dport 546 -j ACCEPT
    
    # Log denied packets
    ip6tables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "ip6tables denied: " --log-level 7
    
    # Save iptables rules
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    
    # Configure sysctl for security
    cat > /etc/sysctl.d/99-security.conf << 'SYSCTL'
# IPv4 Security Settings
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# IPv6 Security Settings
# Disable source packet routing
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Block IPv6 redirects
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Increase system file descriptor limit
fs.file-max = 65535
SYSCTL
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-security.conf
    
    # Secure SSH access
    cat > /etc/ssh/sshd_config.d/secure_ssh.conf << 'SSHCONF'
PermitRootLogin prohibit-password
PasswordAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 20
MaxSessions 2
SSHCONF
    
    # Restart SSH service
    systemctl restart sshd
    echo "Security measures configured successfully."
    # ===== END SECURITY SETUP =====
    
    # Enable and start BIRD
    systemctl enable bird
    systemctl start bird
    
    # Verify BGP sessions
    echo "Checking BGP status:"
    birdc show proto all vultr6
    
    # Check RPKI status
    echo "Checking RPKI status:"
    sleep 30  # Give RPKI time to connect
    echo "Routinator status:"
    birdc show protocols rpki_routinator
    echo "ARIN validator status:" 
    birdc show protocols rpki_arin
    echo "RIPE validator status:"
    birdc show protocols rpki_ripe
    echo "Cloudflare validator status:"
    birdc show protocols rpki_cloudflare
    
    # Check Routinator service
    echo "Routinator service status:"
    systemctl status routinator
    
    # Check security services
    echo "CrowdSec status:"
    systemctl status crowdsec
    echo "Fail2ban status:"
    systemctl status fail2ban
EOF
  
  echo "IPv6 BIRD configuration deployed to $server_type server"
}

# Function to check if existing VM is shut down
check_existing_vm() {
  echo "Checking if existing birdbgp-losangeles VM is shut down..."
  
  # Search for VM by label
  existing_vm=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances?label=birdbgp-losangeles" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  # Check if VM exists
  vm_id=$(echo $existing_vm | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ -z "$vm_id" ]; then
    echo "No existing birdbgp-losangeles VM found. Proceeding with deployment."
    return 0
  fi
  
  # Check VM status
  vm_status=$(echo $existing_vm | grep -o '"status":"[^"]*' | cut -d'"' -f4)
  
  if [ "$vm_status" == "active" ]; then
    echo "ERROR: Existing birdbgp-losangeles VM is still active!"
    echo "Please shut down the VM before proceeding with deployment."
    echo "VM ID: $vm_id"
    echo ""
    echo "To shut down the VM, you can use Vultr's control panel or API:"
    echo "curl -X POST \"${VULTR_API_ENDPOINT}instances/$vm_id/halt\" -H \"Authorization: Bearer \${VULTR_API_KEY}\""
    return 1
  elif [ "$vm_status" == "stopped" ]; then
    echo "WARNING: Existing birdbgp-losangeles VM is stopped but not destroyed."
    echo "You may want to destroy it after successful deployment."
    echo "VM ID: $vm_id"
    echo ""
    echo "To destroy the VM, you can use Vultr's control panel or API:"
    echo "curl -X DELETE \"${VULTR_API_ENDPOINT}instances/$vm_id\" -H \"Authorization: Bearer \${VULTR_API_KEY}\""
    
    # Prompt for confirmation to continue
    read -p "Continue with deployment anyway? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
      echo "Deployment aborted."
      return 1
    fi
    return 0
  else
    echo "Existing birdbgp-losangeles VM is in state: $vm_status"
    echo "This appears to be safe for proceeding with deployment."
    return 0
  fi
}

# Main deployment function
deploy() {
  # Set up error handling
  # If the script exits with an error, run the cleanup function
  trap 'echo "Error detected, cleaning up resources..."; cleanup_resources' ERR
  
  echo "Starting Vultr BGP Anycast deployment..."
  
  # Check if existing VM is shut down
  check_existing_vm || exit 1
  
  # Create IPv4 instances (3 servers as per documentation)
  create_instance "${IPV4_REGIONS[0]}" "ewr-ipv4-bgp-primary-1c1g" "1" "false" || { echo "Failed to create primary instance"; exit 1; }
  create_instance "${IPV4_REGIONS[1]}" "mia-ipv4-bgp-secondary-1c1g" "2" "false" || { echo "Failed to create secondary instance"; exit 1; }
  create_instance "${IPV4_REGIONS[2]}" "ord-ipv4-bgp-tertiary-1c1g" "3" "false" || { echo "Failed to create tertiary instance"; exit 1; }
  
  # Create IPv6 instance (1 server as per documentation)
  create_instance "${IPV6_REGION}" "lax-ipv6-bgp-1c1g" "1" "true" || { echo "Failed to create IPv6 instance"; exit 1; }
  
  # Create floating IPs for each instance
  create_floating_ip "$(cat ewr-ipv4-bgp-primary-1c1g_id.txt)" "${IPV4_REGIONS[0]}" "ipv4" || { echo "Failed to create floating IP for primary instance"; exit 1; }
  create_floating_ip "$(cat mia-ipv4-bgp-secondary-1c1g_id.txt)" "${IPV4_REGIONS[1]}" "ipv4" || { echo "Failed to create floating IP for secondary instance"; exit 1; }
  create_floating_ip "$(cat ord-ipv4-bgp-tertiary-1c1g_id.txt)" "${IPV4_REGIONS[2]}" "ipv4" || { echo "Failed to create floating IP for tertiary instance"; exit 1; }
  create_floating_ip "$(cat lax-ipv6-bgp-1c1g_id.txt)" "${IPV6_REGION}" "ipv6" || { echo "Failed to create floating IP for IPv6 instance"; exit 1; }
  
  # Store the existing VM ID for potential cleanup
  existing_vm=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances?label=birdbgp-losangeles" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  vm_id=$(echo $existing_vm | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ ! -z "$vm_id" ]; then
    echo "$vm_id" > "birdbgp-losangeles_old_id.txt"
  fi
  
  # Generate BIRD configurations
  generate_ipv4_bird_config "ewr-ipv4-primary" "$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)" 0
  generate_ipv4_bird_config "mia-ipv4-secondary" "$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)" 1
  generate_ipv4_bird_config "ord-ipv4-tertiary" "$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)" 2
  generate_ipv6_bird_config "lax-ipv6" "$(cat lax-ipv6-bgp-1c1g_ipv4.txt)" "$(cat lax-ipv6-bgp-1c1g_ipv6.txt)"
  
  # Deploy BIRD configurations
  deploy_ipv4_bird_config "ewr-ipv4-primary" "$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)" "$(cat floating_ipv4_${IPV4_REGIONS[0]}.txt)"
  deploy_ipv4_bird_config "mia-ipv4-secondary" "$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)" "$(cat floating_ipv4_${IPV4_REGIONS[1]}.txt)"
  deploy_ipv4_bird_config "ord-ipv4-tertiary" "$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)" "$(cat floating_ipv4_${IPV4_REGIONS[2]}.txt)"
  deploy_ipv6_bird_config "lax-ipv6" "$(cat lax-ipv6-bgp-1c1g_ipv4.txt)" "$(cat floating_ipv6_${IPV6_REGION}.txt)"
  
  # Remove the error trap as deployment completed successfully
  trap - ERR
  
  echo "Deployment complete!"
  echo ""
  echo "IPv4 BGP Servers:"
  echo "Primary (Newark): $(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt) with floating IP $(cat floating_ipv4_${IPV4_REGIONS[0]}.txt)"
  echo "Secondary (Miami): $(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt) with floating IP $(cat floating_ipv4_${IPV4_REGIONS[1]}.txt)"
  echo "Tertiary (Chicago): $(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt) with floating IP $(cat floating_ipv4_${IPV4_REGIONS[2]}.txt)"
  echo ""
  echo "IPv6 BGP Server:"
  echo "IPv6 Server (Los Angeles): $(cat lax-ipv6-bgp-1c1g_ipv4.txt) (IPv6: $(cat lax-ipv6-bgp-1c1g_ipv6.txt)) with floating IPv6 $(cat floating_ipv6_${IPV6_REGION}.txt)"
  echo ""
  echo "To test failover, SSH to the primary server and run: systemctl stop bird"
  echo "Then check that traffic is redirected to the secondary server."
}

# Monitor function
monitor() {
  echo "Monitoring BGP Anycast infrastructure..."
  
  # Check if instance ID files exist
  if [ ! -f "ewr-ipv4-bgp-primary-1c1g_id.txt" ] || [ ! -f "mia-ipv4-bgp-secondary-1c1g_id.txt" ] || [ ! -f "ord-ipv4-bgp-tertiary-1c1g_id.txt" ] || [ ! -f "lax-ipv6-bgp-1c1g_id.txt" ]; then
    echo "Error: Instance ID files not found. Have you deployed the infrastructure?"
    exit 1
  fi
  
  # Get instance IDs
  ipv4_primary_id=$(cat ewr-ipv4-bgp-primary-1c1g_id.txt)
  ipv4_secondary_id=$(cat mia-ipv4-bgp-secondary-1c1g_id.txt)
  ipv4_tertiary_id=$(cat ord-ipv4-bgp-tertiary-1c1g_id.txt)
  ipv6_id=$(cat lax-ipv6-bgp-1c1g_id.txt)
  
  # Get instance IPs
  ipv4_primary_ip=$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)
  ipv4_secondary_ip=$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)
  ipv4_tertiary_ip=$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)
  ipv6_ip=$(cat lax-ipv6-bgp-1c1g_ipv4.txt)
  
  # Check instance status
  echo "Checking instance status..."
  
  for id in "$ipv4_primary_id" "$ipv4_secondary_id" "$ipv4_tertiary_id" "$ipv6_id"; do
    status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    echo "Instance $id status: $status"
  done
  
  # Check floating IP status
  echo "Checking floating IP status..."
  
  for region in "${IPV4_REGIONS[@]}" "${IPV6_REGION}"; do
    if [ -f "floating_ipv4_${region}_id.txt" ]; then
      floating_id=$(cat "floating_ipv4_${region}_id.txt")
      floating_ip=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
      
      echo "Floating IPv4 in $region: $floating_ip"
    fi
    
    if [ -f "floating_ipv6_${region}_id.txt" ]; then
      floating_id=$(cat "floating_ipv6_${region}_id.txt")
      floating_ip=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
      
      echo "Floating IPv6 in $region: $floating_ip"
    fi
  done
  
  # Check BGP status on each server
  echo "Checking BGP status on IPv4 primary server..."
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show proto all vultr"
  
  echo "Checking BGP status on IPv4 secondary server..."
  ssh $SSH_OPTIONS root@$ipv4_secondary_ip "birdc show proto all vultr"
  
  echo "Checking BGP status on IPv4 tertiary server..."
  ssh $SSH_OPTIONS root@$ipv4_tertiary_ip "birdc show proto all vultr"
  
  echo "Checking BGP status on IPv6 server..."
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show proto all vultr6"
  
  # Check RPKI status on each server
  echo "Checking RPKI status on servers..."
  
  # Create a separator function for cleaner output
  separator() {
    echo -e "\n-------------------------------------------------------------\n"
  }
  
  separator
  echo "PRIMARY SERVER RPKI STATUS (Newark)"
  separator
  
  echo "1. Routinator status (local with ARIN TAL priority):"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show protocols rpki_routinator"
  
  echo "2. ARIN external validator status:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show protocols rpki_arin"
  
  echo "3. RIPE validator status:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show protocols rpki_ripe"
  
  echo "4. Cloudflare validator status:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show protocols rpki_cloudflare"
  
  separator
  echo "IPV6 SERVER RPKI STATUS (Los Angeles)"
  separator
  
  echo "1. Routinator status (local with ARIN TAL priority):"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show protocols rpki_routinator"
  
  echo "2. ARIN external validator status:"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show protocols rpki_arin"
  
  echo "3. RIPE validator status:"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show protocols rpki_ripe"
  
  echo "4. Cloudflare validator status:"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show protocols rpki_cloudflare"
  
  separator
  echo "ROUTINATOR SERVICE STATUS"
  separator
  
  echo "Primary server Routinator service:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "systemctl status routinator"
  
  echo "IPv6 server Routinator service:"
  ssh $SSH_OPTIONS root@$ipv6_ip "systemctl status routinator"
  
  separator
  echo "RPKI VALIDATION FOR OUR IP RANGES"
  separator
  
  echo "IPv4 Prefix (${OUR_IPV4_BGP_RANGE}) validation status:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc eval 'roa_check(rpki_table, ${OUR_IPV4_BGP_RANGE}, ${OUR_AS})'"
  
  echo "IPv6 Prefix (${OUR_IPV6_BGP_RANGE}) validation status:"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc eval 'roa_check(rpki_table, ${OUR_IPV6_BGP_RANGE}, ${OUR_AS})'"
  
  separator
  echo "RPKI ROA TABLE STATISTICS"
  separator
  
  echo "ROA table statistics from primary server:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show route table rpki_table count"
  
  echo "RPKI cache status in Routinator:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "routinator vrps stats"
  
  echo "Monitoring complete!"
}

# Function to test failover
test_failover() {
  if [ ! -f "ewr-ipv4-bgp-primary-1c1g_ipv4.txt" ]; then
    echo "Error: Primary server IP file not found. Have you deployed the infrastructure?"
    exit 1
  fi
  
  primary_ip=$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)
  
  echo "Testing failover by stopping BIRD on primary server..."
  
  ssh $SSH_OPTIONS root@$primary_ip "systemctl stop bird"
  
  echo "BIRD stopped on primary server. Traffic should now route to the secondary server."
  echo "To check, try accessing your service on the floating IP or the anycast IP range."
  echo ""
  echo "To restore service on the primary server, run:"
  echo "ssh root@$primary_ip \"systemctl start bird\""
}

# Function to test SSH connectivity
test_ssh() {
  if [ $# -lt 1 ]; then
    echo "Usage: $0 test-ssh <hostname_or_ip> [username]"
    echo "Example: $0 test-ssh 45.32.70.31 root"
    exit 1
  fi
  
  local host=$1
  local user=${2:-root}
  
  echo "Testing SSH connectivity to $user@$host..."
  
  # First try using SSH agent with known working key
  echo "Attempting connection using SSH agent with known working key (nt@infinitum-nihil.com)..."
  ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o IdentityFile=$SSH_KEY_PATH $user@$host echo "Connection successful" 2>/dev/null
  
  # If that fails, try all keys in agent
  if [ $? -ne 0 ]; then
    echo "Trying with all keys in agent..."
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$host echo "Connection successful" 2>/dev/null
  fi
  
  agent_result=$?
  if [ $agent_result -eq 0 ]; then
    echo "✅ Successfully connected to $user@$host using SSH agent."
    return 0
  else
    echo "❌ Could not connect using SSH agent."
  fi
  
  # Then try using the key from .env if it exists
  if [ ! -z "$NT_SSH_PUBLIC_KEY" ]; then
    echo "Trying with key from .env file..."
    
    # Create a temporary private key prompt
    echo "NOTE: To test with the key in .env, I need your private key."
    echo "This is the matching private key for: $(echo "$NT_SSH_PUBLIC_KEY" | cut -d ' ' -f 3)"
    echo "If you don't want to proceed, press Ctrl+C now."
    
    # Create temporary files for key testing
    temp_key_dir=$(mktemp -d)
    temp_pub_key="$temp_key_dir/id_ed25519.pub"
    temp_priv_key="$temp_key_dir/id_ed25519"
    
    # Write public key to temp file
    echo "$NT_SSH_PUBLIC_KEY" > "$temp_pub_key"
    
    # Ask for private key
    echo "Please paste your private key (will not be stored permanently):"
    echo "-----BEGIN OPENSSH PRIVATE KEY-----"
    cat > "$temp_priv_key" << EOT
-----BEGIN OPENSSH PRIVATE KEY-----
EOT
    
    # Read private key content
    while IFS= read -r line; do
      # Stop at end marker
      if [[ $line == "-----END OPENSSH PRIVATE KEY-----" ]]; then
        echo "$line" >> "$temp_priv_key"
        break
      fi
      echo "$line" >> "$temp_priv_key"
    done
    
    echo "-----END OPENSSH PRIVATE KEY-----" >> "$temp_priv_key"
    
    # Set correct permissions
    chmod 600 "$temp_priv_key"
    chmod 644 "$temp_pub_key"
    
    # Test connection with the key
    echo "Testing connection with provided key..."
    ssh -i "$temp_priv_key" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$host echo "Connection successful" 2>/dev/null
    
    key_result=$?
    
    # Clean up
    rm -rf "$temp_key_dir"
    
    if [ $key_result -eq 0 ]; then
      echo "✅ Successfully connected to $user@$host using provided key."
      return 0
    else
      echo "❌ Could not connect using provided key."
    fi
  fi
  
  # Try with ssh-add if available
  if command -v ssh-add &> /dev/null; then
    echo "You can try adding your key to ssh-agent:"
    echo "  ssh-add /path/to/your/private/key"
    echo "Then run this test again."
  fi
  
  echo "SSH connectivity test failed. Please check:"
  echo "1. Your SSH key is authorized on the server"
  echo "2. The server is accessible and running SSH"
  echo "3. No firewall is blocking SSH access"
  
  return 1
}

# Function to clean up resources on failure
cleanup_resources() {
  echo "Starting cleanup of created resources..."
  
  # Clean up instances if they were created
  for prefix in "ewr-ipv4-bgp-primary-1c1g" "mia-ipv4-bgp-secondary-1c1g" "ord-ipv4-bgp-tertiary-1c1g" "lax-ipv6-bgp-1c1g"; do
    if [ -f "${prefix}_id.txt" ]; then
      instance_id=$(cat "${prefix}_id.txt")
      echo "Deleting instance $prefix (ID: $instance_id)..."
      
      delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}instances/$instance_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
        
      echo "Instance deletion initiated for $prefix."
      rm -f "${prefix}_id.txt"
      rm -f "${prefix}_ipv4.txt"
      rm -f "${prefix}_ipv6.txt"
    fi
  done
  
  # Clean up floating IPs if they were created
  for region in "${IPV4_REGIONS[@]}" "${IPV6_REGION}"; do
    # Check for IPv4 floating IPs
    if [ -f "floating_ipv4_${region}_id.txt" ]; then
      floating_id=$(cat "floating_ipv4_${region}_id.txt")
      echo "Deleting floating IPv4 in region $region (ID: $floating_id)..."
      
      delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}reserved-ips/$floating_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
        
      echo "Floating IPv4 deletion initiated for region $region."
      rm -f "floating_ipv4_${region}_id.txt"
      rm -f "floating_ipv4_${region}.txt"
    fi
    
    # Check for IPv6 floating IPs
    if [ -f "floating_ipv6_${region}_id.txt" ]; then
      floating_id=$(cat "floating_ipv6_${region}_id.txt")
      echo "Deleting floating IPv6 in region $region (ID: $floating_id)..."
      
      delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}reserved-ips/$floating_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
        
      echo "Floating IPv6 deletion initiated for region $region."
      rm -f "floating_ipv6_${region}_id.txt"
      rm -f "floating_ipv6_${region}.txt"
    fi
  done
  
  # Clean up SSH key if it was created
  if [ -f "vultr_ssh_key_id.txt" ]; then
    ssh_key_id=$(cat "vultr_ssh_key_id.txt")
    echo "Deleting SSH key in Vultr (ID: $ssh_key_id)..."
    
    delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}ssh-keys/$ssh_key_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
      
    echo "SSH key deletion initiated."
    rm -f "vultr_ssh_key_id.txt"
  fi
  
  echo "Cleanup completed."
  echo "You may want to verify in the Vultr control panel that all resources were properly deleted."
}

# Function to clean up old birdbgp-losangeles VM
cleanup_old_vm() {
  if [ ! -f "birdbgp-losangeles_old_id.txt" ]; then
    echo "Error: Old VM ID file not found. No old VM to clean up."
    exit 1
  fi
  
  old_vm_id=$(cat birdbgp-losangeles_old_id.txt)
  
  echo "Checking status of old birdbgp-losangeles VM (ID: $old_vm_id)..."
  
  # Get VM status
  vm_info=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$old_vm_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  vm_status=$(echo $vm_info | grep -o '"status":"[^"]*' | cut -d'"' -f4)
  
  echo "Old VM status: $vm_status"
  
  if [ "$vm_status" == "active" ]; then
    echo "WARNING: Old VM is still active. Stopping it first..."
    
    # Stop VM
    stop_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances/$old_vm_id/halt" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    echo "Waiting for VM to stop..."
    sleep 30
    
    # Check status again
    vm_info=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$old_vm_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    vm_status=$(echo $vm_info | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    if [ "$vm_status" == "active" ]; then
      echo "ERROR: Failed to stop old VM. Please stop it manually and try again."
      echo "Command to stop: curl -X POST \"${VULTR_API_ENDPOINT}instances/$old_vm_id/halt\" -H \"Authorization: Bearer \${VULTR_API_KEY}\""
      exit 1
    fi
  fi
  
  # Confirm deletion
  echo "Are you sure you want to PERMANENTLY DELETE the old birdbgp-losangeles VM?"
  echo "This action CANNOT be undone!"
  read -p "Type 'DELETE' to confirm: " confirm
  
  if [ "$confirm" != "DELETE" ]; then
    echo "Deletion aborted."
    exit 1
  fi
  
  # Delete VM
  echo "Deleting old VM..."
  delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}instances/$old_vm_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  echo "Old VM deletion initiated."
  echo "Please verify in the Vultr control panel that the VM has been deleted."
  
  # Remove ID file
  rm -f "birdbgp-losangeles_old_id.txt"
}

# Function to enable RTBH for specific IPs under attack
apply_rtbh() {
  local server_ip=$1
  local target_ip=$2
  
  echo "Applying RTBH for IP $target_ip via server $server_ip..."
  
  if [[ ! $target_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! $target_ip =~ ^[0-9a-fA-F:]+$ ]]; then
    echo "Error: Invalid IP address format: $target_ip"
    return 1
  fi
  
  # Extract the protocol (IPv4 or IPv6)
  local ip_protocol="ipv4"
  if [[ $target_ip =~ ":" ]]; then
    ip_protocol="ipv6"
  fi
  
  # Determine the appropriate prefix length (Host routes)
  local prefix="/32"
  if [ "$ip_protocol" == "ipv6" ]; then
    prefix="/128"
  fi
  
  # Apply RTBH configuration via SSH
  ssh $SSH_OPTIONS root@$server_ip << EOF
    # Create a temporary script for RTBH configuration
    cat > /tmp/rtbh_config.sh << 'SCRIPT'
#!/bin/bash
# Add specific IP to be blackholed
cat > /etc/bird/rtbh.conf << 'RTBH'
# Remote Triggered Black Hole routes
protocol static rtbh_routes {
  ${ip_protocol};
  route ${target_ip}${prefix} blackhole;
}
RTBH

# Include RTBH file in BIRD config if not already included
grep -q 'include "rtbh.conf";' /etc/bird/bird.conf || sed -i '/# RPKI Configuration/i include "rtbh.conf";\\n' /etc/bird/bird.conf

# Modify the export filter to add the blackhole community if it doesn't exist
if ! grep -q '20473,666' /etc/bird/bird.conf; then
  # Find the position to insert the community
  if grep -q 'export filter' /etc/bird/bird.conf; then
    line_number=\$(grep -n 'bgp_community.add' /etc/bird/bird.conf | head -1 | cut -d':' -f1)
    if [ ! -z "\$line_number" ]; then
      sed -i "\${line_number}i\        # Add blackhole community for RTBH\\n        if (dest = RTD_BLACKHOLE) then bgp_community.add((20473,666));" /etc/bird/bird.conf
    fi
  fi
fi

# Restart BIRD to apply changes
systemctl restart bird
echo "RTBH enabled for ${target_ip}${prefix}"
SCRIPT

    # Make script executable and run it
    chmod +x /tmp/rtbh_config.sh
    /tmp/rtbh_config.sh
    
    # Verify RTBH configuration
    echo "Checking RTBH route status:"
    birdc show route protocol rtbh_routes
EOF

  echo "RTBH configured for $target_ip via $server_ip"
  echo "Traffic to this IP will be dropped at Vultr's edge."
  echo "Warning: This IP is now inaccessible. To restore access, remove the RTBH configuration."
}

# Function to implement ASPA support and protocol configuration
configure_aspa() {
  local server_ip=$1
  
  echo "Configuring ASPA support on server $server_ip..."
  
  ssh $SSH_OPTIONS root@$server_ip << EOF
    # Create ASPA configuration file
    cat > /etc/bird/aspa.conf << 'ASPA'
# ASPA (Autonomous System Provider Authorization) Configuration
# Defines your expected upstreams to prevent route leaks and hijacking

# Import ASPA data from Routinator
# Note: Routinator must be built from source with --features aspa flag
protocol rpki aspa_source {
  table aspa_table;
  remote "localhost" port 8323;
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  aspa4 { table aspa_table; };
  aspa6 { table aspa_table; };
  # Set extended timeouts to account for ASPA processing
  retry keep 900;
  refresh keep 900;
  expire keep 10800;
}

# Authorized providers for our ASN
# This defines the only ASNs that should be seen as upstreams of our ASN
function aspa_check() {
  # Define Vultr ASN as our only authorized upstream
  if (bgp_path.len > 1) then {
    if (bgp_path[1] != 64515) then {
      print "ASPA: Invalid upstream AS for our ASN. Expected 64515 (Vultr), got ", bgp_path[1];
      return false;
    }
  }
  return true;
}

# Enhanced RPKI function that also checks ASPA status
function enhanced_route_security() {
  # First check RPKI
  if (roa_check(rpki_table, net, bgp_path.last) = ROA_INVALID) then {
    print "RPKI: Invalid route: ", net, " ASN: ", bgp_path.last;
    reject;
  }
  
  # Then check ASPA
  if (!aspa_check()) then {
    reject;
  }
  
  # Mark routes with RPKI status in communities
  if (roa_check(rpki_table, net, bgp_path.last) = ROA_VALID) then {
    bgp_community.add((${OUR_AS}, 1001)); # RPKI valid
  } else if (roa_check(rpki_table, net, bgp_path.last) = ROA_UNKNOWN) then {
    bgp_community.add((${OUR_AS}, 1002)); # RPKI unknown
  }
  
  accept;
}
ASPA

    # Include ASPA file in BIRD config
    grep -q 'include "aspa.conf";' /etc/bird/bird.conf || sed -i '/# RPKI Configuration/i include "aspa.conf";\\n' /etc/bird/bird.conf
    
    # Update import filters to use enhanced_route_security instead of rpki_check
    sed -i 's/import where rpki_check()/import where enhanced_route_security()/g' /etc/bird/bird.conf
    
    # Restart BIRD to apply changes
    systemctl restart bird
    
    echo "ASPA support configured. Vultr (AS64515) is now the only authorized upstream."
EOF

  echo "ASPA support configured on server $server_ip"
  echo "The server will now verify that BGP paths only include authorized upstreams."
  echo "This helps prevent route leaks and certain forms of BGP hijacking."
}

# Function to add specific BGP communities to manipulate routing
apply_bgp_community() {
  local server_ip=$1
  local community_type=$2
  local target_as=${3:-0} # Optional target AS
  
  echo "Applying BGP community to server $server_ip: $community_type"
  
  # Build the community string based on the type and target
  local community_cmd=""
  
  case "$community_type" in
    no-advertise)
      if [ "$target_as" -eq 0 ]; then
        # Don't advertise out of AS20473
        community_cmd="bgp_community.add((20473,6000));"
      else
        # Don't advertise to specific AS
        community_cmd="bgp_community.add((64600,$target_as));"
        community_cmd="$community_cmd\nbgp_large_community.add((20473,6000,$target_as));"
      fi
      ;;
    prepend-1x)
      if [ "$target_as" -eq 0 ]; then
        # Prepend 1x to all peers
        community_cmd="bgp_community.add((20473,6001));"
      else
        # Prepend 1x to specific AS
        community_cmd="bgp_community.add((64601,$target_as));"
        community_cmd="$community_cmd\nbgp_large_community.add((20473,6001,$target_as));"
      fi
      ;;
    prepend-2x)
      if [ "$target_as" -eq 0 ]; then
        # Prepend 2x to all peers
        community_cmd="bgp_community.add((20473,6002));"
      else
        # Prepend 2x to specific AS
        community_cmd="bgp_community.add((64602,$target_as));"
        community_cmd="$community_cmd\nbgp_large_community.add((20473,6002,$target_as));"
      fi
      ;;
    prepend-3x)
      if [ "$target_as" -eq 0 ]; then
        # Prepend 3x to all peers
        community_cmd="bgp_community.add((20473,6003));"
      else
        # Prepend 3x to specific AS
        community_cmd="bgp_community.add((64603,$target_as));"
        community_cmd="$community_cmd\nbgp_large_community.add((20473,6003,$target_as));"
      fi
      ;;
    no-ixp)
      # Do not announce to IXP peers
      community_cmd="bgp_community.add((20473,6601));"
      ;;
    ixp-only)
      # Announce to IXP route servers only
      community_cmd="bgp_community.add((20473,6602));"
      ;;
    blackhole)
      # Export blackhole to all peers
      community_cmd="bgp_community.add((20473,666));"
      ;;
    *)
      echo "Unknown community type: $community_type"
      echo "Available types: no-advertise, prepend-1x, prepend-2x, prepend-3x, no-ixp, ixp-only, blackhole"
      return 1
      ;;
  esac
  
  # Update BIRD configuration to add the community
  ssh $SSH_OPTIONS root@$server_ip << EOF
    # Create a temporary file with the community addition
    cat > /tmp/bird_community_update.sh << 'SCRIPT'
#!/bin/bash
# Add community to export filter
sed -i '/export filter {/,/accept;/ s/accept;/# Community added by script\n        $community_cmd\n        accept;/' /etc/bird/bird.conf
# Restart BIRD to apply changes
systemctl restart bird
SCRIPT
    
    # Make it executable and run it
    chmod +x /tmp/bird_community_update.sh
    /tmp/bird_community_update.sh
    
    # Verify the changes
    echo "Checking BGP status after community update:"
    birdc show route all
    birdc show protocols
EOF
  
  echo "BGP community applied successfully to $server_ip"
}

# Parse command line arguments
case "$1" in
  deploy)
    deploy
    ;;
  monitor)
    monitor
    ;;
  test-failover)
    test_failover
    ;;
  test-ssh)
    if [ $# -lt 2 ]; then
      echo "Usage: $0 test-ssh <hostname_or_ip> [username]"
      echo "Example: $0 test-ssh 45.32.70.31 root"
      exit 1
    fi
    test_ssh "$2" "${3:-root}"
    ;;
  rtbh)
    if [ $# -lt 3 ]; then
      echo "Usage: $0 rtbh <server_ip> <target_ip>"
      echo "Example: $0 rtbh 45.32.70.31 192.0.2.1"
      echo "This will blackhole traffic to the target IP at Vultr's edge using BGP community 20473:666"
      exit 1
    fi
    apply_rtbh "$2" "$3"
    ;;
  aspa)
    if [ $# -lt 2 ]; then
      echo "Usage: $0 aspa <server_ip>"
      echo "Example: $0 aspa 45.32.70.31"
      echo "This will configure ASPA support to allow only Vultr as your upstream"
      exit 1
    fi
    configure_aspa "$2"
    ;;
  community)
    if [ $# -lt 3 ]; then
      echo "Usage: $0 community <server_ip> <community_type> [target_as]"
      echo "Available community types: no-advertise, prepend-1x, prepend-2x, prepend-3x, no-ixp, ixp-only, blackhole"
      exit 1
    fi
    apply_bgp_community "$2" "$3" "${4:-0}"
    ;;
  cleanup-old-vm)
    cleanup_old_vm
    ;;
  cleanup)
    echo "This will clean up ALL resources created by this script."
    echo "WARNING: This action cannot be undone!"
    read -p "Are you sure you want to proceed? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
      cleanup_resources
    else
      echo "Cleanup aborted."
    fi
    ;;
  *)
    echo "Usage: $0 {deploy|monitor|test-failover|test-ssh|rtbh|aspa|community|cleanup-old-vm|cleanup}"
    echo "       $0 test-ssh <hostname_or_ip> [username]"
    echo "       $0 rtbh <server_ip> <target_ip>"
    echo "       $0 aspa <server_ip>"
    echo "       $0 community <server_ip> <community_type> [target_as]"
    echo ""
    echo "Commands:"
    echo "  deploy         - Deploy the BGP Anycast infrastructure"
    echo "  monitor        - Monitor the status of the BGP Anycast infrastructure"
    echo "  test-failover  - Test failover by stopping BIRD on the primary server"
    echo "  test-ssh       - Test SSH connectivity to a server"
    echo "  rtbh           - Configure Remote Triggered Black Hole for DDoS mitigation"
    echo "  aspa           - Configure ASPA validation for enhanced security"
    echo "  community      - Apply BGP communities to manipulate routing"
    echo "  cleanup-old-vm - Clean up the old birdbgp-losangeles VM after successful deployment"
    echo "  cleanup        - Clean up ALL resources created by this script"
    exit 1
    ;;
esac

exit 0