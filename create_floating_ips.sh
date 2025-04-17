#!/bin/bash

# Source .env file to get API credentials
source "$(dirname "$0")/.env"

# IMPORTANT: Vultr has a quota limit for reserved IPs that includes both active AND recently deleted IPs
# Deleting IPs will not immediately free up quota - Vultr has a cooldown period (likely 24+ hours)
# before recently deleted IPs stop counting against your quota.
# This script will automatically retry with a countdown timer when quota limits are hit.

# Configuration
MAX_RETRIES=6          # Maximum retry attempts per IP (6 x 20 min = 2 hours)
RETRY_DELAY=1200       # Delay in seconds between retries (20 minutes)
PROGRESS_INTERVAL=10   # Update countdown every X seconds

# IP tracking log for quota management
IP_TRACKING_FILE="$(dirname "$0")/reserved_ip_creations.log"
IP_PROGRESS_FILE="$(dirname "$0")/reserved_ip_progress.json"
touch "$IP_TRACKING_FILE"

# Record reserved IP creation
record_ip_creation() {
  local ip=$1
  local id=$2
  local region=$3
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "$timestamp | CREATED | $id | $ip | $region" >> "$IP_TRACKING_FILE"
}

# Function to display a countdown timer
countdown() {
  local remaining=$1
  local message=$2
  local start_time=$(date +%s)
  local end_time=$((start_time + remaining))
  local current_time=$start_time
  
  echo -n "$message "
  
  while [ $current_time -lt $end_time ]; do
    # Calculate minutes and seconds remaining
    local time_left=$((end_time - current_time))
    local mins=$((time_left / 60))
    local secs=$((time_left % 60))
    
    # Display time remaining with proper formatting
    printf "\r$message %02d:%02d remaining " $mins $secs
    
    # Update every X seconds to reduce CPU usage
    sleep $PROGRESS_INTERVAL
    current_time=$(date +%s)
  done
  
  printf "\r$message Complete!          \n"
}

# Load progress if it exists
if [ -f "$IP_PROGRESS_FILE" ]; then
  echo "Found existing progress file. Resuming from previous state..."
  PRIMARY_DONE=$(grep -o '"primary_done":[^,}]*' "$IP_PROGRESS_FILE" | cut -d: -f2 | tr -d ' "')
  SECONDARY_DONE=$(grep -o '"secondary_done":[^,}]*' "$IP_PROGRESS_FILE" | cut -d: -f2 | tr -d ' "')
  TERTIARY_DONE=$(grep -o '"tertiary_done":[^,}]*' "$IP_PROGRESS_FILE" | cut -d: -f2 | tr -d ' "')
  IPV6_DONE=$(grep -o '"ipv6_done":[^,}]*' "$IP_PROGRESS_FILE" | cut -d: -f2 | tr -d ' "')
else
  # Initialize progress tracking
  PRIMARY_DONE=false
  SECONDARY_DONE=false
  TERTIARY_DONE=false
  IPV6_DONE=false
  echo "{\"primary_done\":false,\"secondary_done\":false,\"tertiary_done\":false,\"ipv6_done\":false}" > "$IP_PROGRESS_FILE"
fi

# Get our instance IDs and regions
INSTANCES=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")

# Extract instance information
PRIMARY_ID=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-primary[^}]*}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
PRIMARY_REGION=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-primary[^}]*}" | grep -o '"region":"[^"]*' | cut -d'"' -f4)

SECONDARY_ID=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-secondary[^}]*}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
SECONDARY_REGION=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-secondary[^}]*}" | grep -o '"region":"[^"]*' | cut -d'"' -f4)

TERTIARY_ID=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-tertiary[^}]*}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
TERTIARY_REGION=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-tertiary[^}]*}" | grep -o '"region":"[^"]*' | cut -d'"' -f4)

IPV6_ID=$(echo "$INSTANCES" | grep -o "{[^}]*ipv6-bgp[^}]*}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
IPV6_REGION=$(echo "$INSTANCES" | grep -o "{[^}]*ipv6-bgp[^}]*}" | grep -o '"region":"[^"]*' | cut -d'"' -f4)

echo "Found instances:"
echo "Primary IPv4:   ID=$PRIMARY_ID, Region=$PRIMARY_REGION"
echo "Secondary IPv4: ID=$SECONDARY_ID, Region=$SECONDARY_REGION"
echo "Tertiary IPv4:  ID=$TERTIARY_ID, Region=$TERTIARY_REGION"
echo "IPv6:           ID=$IPV6_ID, Region=$IPV6_REGION"
echo

# Update progress file with completed status
update_progress() {
  local stage=$1
  local completed=$2
  
  case "$stage" in
    primary)
      PRIMARY_DONE=$completed
      ;;
    secondary)
      SECONDARY_DONE=$completed
      ;;
    tertiary)
      TERTIARY_DONE=$completed
      ;;
    ipv6)
      IPV6_DONE=$completed
      ;;
  esac
  
  # Write updated progress to file
  echo "{\"primary_done\":$PRIMARY_DONE,\"secondary_done\":$SECONDARY_DONE,\"tertiary_done\":$TERTIARY_DONE,\"ipv6_done\":$IPV6_DONE}" > "$IP_PROGRESS_FILE"
  echo "Updated progress: $stage is now $completed"
}

# Function to create a floating IP and attach it to an instance with retry logic
create_and_attach_floating_ip() {
  local instance_id=$1
  local region=$2
  local ip_type=$3
  local label=$4
  local stage=$5
  
  # Check if this stage is already completed from a previous run
  if [ "$stage" = "primary" ] && [ "$PRIMARY_DONE" = "true" ]; then
    echo "Skipping primary IP creation - already completed in a previous run"
    return 0
  elif [ "$stage" = "secondary" ] && [ "$SECONDARY_DONE" = "true" ]; then
    echo "Skipping secondary IP creation - already completed in a previous run"
    return 0
  elif [ "$stage" = "tertiary" ] && [ "$TERTIARY_DONE" = "true" ]; then
    echo "Skipping tertiary IP creation - already completed in a previous run"
    return 0
  elif [ "$stage" = "ipv6" ] && [ "$IPV6_DONE" = "true" ]; then
    echo "Skipping IPv6 IP creation - already completed in a previous run"
    return 0
  fi
  
  # Try multiple times if needed
  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "Creating $ip_type floating IP in region $region ($label) - Attempt $attempt of $MAX_RETRIES..."
    local response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"region\": \"$region\", \"ip_type\": \"$ip_type\", \"label\": \"$label\"}")
    
    # Check if creation succeeded
    if echo "$response" | grep -q "id"; then
      local floating_ip_id=$(echo "$response" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      local floating_ip=$(echo "$response" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
      
      echo "✅ Created floating IP: $floating_ip (ID: $floating_ip_id)"
      # Record the creation for quota tracking
      record_ip_creation "$floating_ip" "$floating_ip_id" "$region"
      
      # Wait before attaching to avoid API rate limits
      echo "Waiting 20 seconds before attaching to avoid API rate limits..."
      sleep 20
      
      # Attach floating IP to instance
      echo "Attaching floating IP $floating_ip to instance $instance_id..."
      local attach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id/attach" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"instance_id\": \"$instance_id\"}")
      
      if [ -z "$attach_response" ]; then
        echo "✅ Successfully attached floating IP to instance $instance_id"
        echo "$floating_ip_id" > "${label}_floating_ip_id.txt"
        echo "$floating_ip" > "${label}_floating_ip.txt"
        
        # Also update the floating-ip files for deploy.sh compatibility
        echo "$floating_ip" > "$(dirname "$0")/floating-ip${ip_type}-${region:0:3}.txt"
        
        # Mark this stage as completed
        update_progress "$stage" true
        
        return 0
      else
        echo "❌ Failed to attach floating IP: $attach_response"
        return 1
      fi
    # Check if the error is due to quota limits
    elif echo "$response" | grep -q "quota"; then
      echo "🕒 Quota limit reached. Waiting before retry..."
      echo "Attempt $attempt of $MAX_RETRIES failed with quota error:"
      echo "$response"
      
      if [ $attempt -lt $MAX_RETRIES ]; then
        echo "Will retry in $((RETRY_DELAY / 60)) minutes..."
        countdown $RETRY_DELAY "Waiting for quota reset:"
      else
        echo "❌ Maximum retry attempts reached. Please try again later or request a quota increase."
        return 1
      fi
    else
      echo "❌ Failed to create floating IP with error:"
      echo "$response"
      return 1
    fi
  done
  
  return 1
}

# Create and attach floating IPs for each instance
echo "Creating and attaching floating IPs..."
echo "--------------------------------------"
echo "This script will retry automatically when quota limits are encountered."
echo "You can safely press Ctrl+C to pause and resume later - progress is saved."
echo "Maximum wait time between retries: $((RETRY_DELAY / 60)) minutes"
echo "Maximum total retries per IP: $MAX_RETRIES"
echo "Current progress: Primary=$PRIMARY_DONE, Secondary=$SECONDARY_DONE, Tertiary=$TERTIARY_DONE, IPv6=$IPV6_DONE"
echo "--------------------------------------"

# Create primary floating IP
create_and_attach_floating_ip "$PRIMARY_ID" "$PRIMARY_REGION" "v4" "ewr-ipv4-primary" "primary" || exit 1

# If successful, wait before trying next IP
if [ "$PRIMARY_DONE" = "true" ]; then
  echo "Primary IP created successfully. Waiting 60 seconds before next IP creation to avoid API rate limits..."
  sleep 60
fi

# Create secondary floating IP
create_and_attach_floating_ip "$SECONDARY_ID" "$SECONDARY_REGION" "v4" "mia-ipv4-secondary" "secondary" || exit 1

# If successful, wait before trying next IP
if [ "$SECONDARY_DONE" = "true" ]; then
  echo "Secondary IP created successfully. Waiting 60 seconds before next IP creation to avoid API rate limits..."
  sleep 60
fi

# Create tertiary floating IP
create_and_attach_floating_ip "$TERTIARY_ID" "$TERTIARY_REGION" "v4" "ord-ipv4-tertiary" "tertiary" || exit 1

# If successful, wait before trying next IP
if [ "$TERTIARY_DONE" = "true" ]; then
  echo "Tertiary IP created successfully. Waiting 60 seconds before next IP creation to avoid API rate limits..."
  sleep 60
fi

# Create IPv6 floating IP if needed
if [ -n "$IPV6_ID" ]; then
  create_and_attach_floating_ip "$IPV6_ID" "$IPV6_REGION" "v6" "lax-ipv6" "ipv6" || exit 1
fi

echo "--------------------------------------"
echo "All floating IPs created and attached successfully!"
echo "You can now continue with BIRD configuration."
echo "Updating deployment state file to stage 3 (IPs attached)..."

# Update deployment state file
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"stage\": 3,\"timestamp\": \"$TIMESTAMP\",\"message\": \"Floating IPs created and attached\",\"ipv4_instances\": [],\"ipv6_instance\": null,\"floating_ipv4_ids\": [],\"floating_ipv6_id\": null}" > "$(dirname "$0")/deployment_state.json"

echo "Deployment state updated. You can now run './deploy.sh continue' to proceed with BIRD configuration."
echo
echo "NOTE: Vultr quota limits include both active AND recently deleted IPs."
echo "If you hit quota issues, you can view your IP creation history in: $IP_TRACKING_FILE"
echo "You'll need to wait 24+ hours after deletion before the quota fully resets."