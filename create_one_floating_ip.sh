#!/bin/bash

# Source .env file to get API credentials
source "$(dirname "$0")/.env"

# Check if region and type are provided
if [ $# -lt 3 ]; then
  echo "Usage: $0 <instance_id> <region> <ip_type> <label>"
  echo "Example: $0 1a0df53b-aab4-4bde-a7ea-1c6387e7b54b ewr v4 ewr-ipv4-primary"
  exit 1
fi

# Get parameters
INSTANCE_ID=$1
REGION=$2
IP_TYPE=$3
LABEL=$4

# Function to create a floating IP and attach it to an instance
create_and_attach_floating_ip() {
  local instance_id=$1
  local region=$2
  local ip_type=$3
  local label=$4
  
  echo "Creating $ip_type floating IP in region $region ($label)..."
  local response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips" \
    -H "Authorization: Bearer ${VULTR_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"region\": \"$region\", \"ip_type\": \"$ip_type\", \"label\": \"$label\"}")
  
  # Check if creation succeeded
  if echo "$response" | grep -q "id"; then
    local floating_ip_id=$(echo "$response" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    local floating_ip=$(echo "$response" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
    
    echo "✅ Created floating IP: $floating_ip (ID: $floating_ip_id)"
    
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
      return 0
    else
      echo "❌ Failed to attach floating IP: $attach_response"
      return 1
    fi
  else
    echo "❌ Failed to create floating IP: $response"
    return 1
  fi
}

# Create and attach the floating IP
create_and_attach_floating_ip "$INSTANCE_ID" "$REGION" "$IP_TYPE" "$LABEL"