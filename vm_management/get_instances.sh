#!/bin/bash

# Source .env file to get API credentials
source "$(dirname "$0")/.env"

# Get all instances
INSTANCES=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")

# Extract instance information and format it nicely
echo "BGP Instances:"
echo "--------------"

# Process each instance type
process_instance() {
  local pattern=$1
  local label=$2
  
  # Extract data
  local data=$(echo "$INSTANCES" | grep -o "{[^}]*$pattern[^}]*}")
  if [ -n "$data" ]; then
    local id=$(echo "$data" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    local region=$(echo "$data" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
    local ip=$(echo "$data" | grep -o '"main_ip":"[^"]*' | cut -d'"' -f4)
    local created=$(echo "$data" | grep -o '"date_created":"[^"]*' | cut -d'"' -f4)
    
    echo "$label:"
    echo "  ID: $id"
    echo "  Region: $region"
    echo "  IP: $ip"
    echo "  Created: $created"
    echo "  Command to create floating IP:"
    echo "  ./create_one_floating_ip.sh $id $region v4 ${pattern}"
    echo
  else
    echo "$label: Not found"
    echo
  fi
}

# Process each instance
process_instance "ipv4-bgp-primary" "Primary IPv4 Instance"
process_instance "ipv4-bgp-secondary" "Secondary IPv4 Instance"
process_instance "ipv4-bgp-tertiary" "Tertiary IPv4 Instance"
process_instance "ipv6-bgp" "IPv6 Instance"

echo
echo "To create and attach a floating IP, run the command provided for each instance."
echo "For the IPv6 instance, change 'v4' to 'v6' in the command."