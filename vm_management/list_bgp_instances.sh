#!/bin/bash

# Source .env file directly
if [ -f "$(dirname "$0")/.env" ]; then
  source "$(dirname "$0")/.env"
else
  echo "Error: .env file not found"
  exit 1
fi

# Ensure VULTR_API_KEY is available
if [ -z "$VULTR_API_KEY" ]; then
  echo "Error: VULTR_API_KEY not found in .env file."
  exit 1
fi

echo "Using API endpoint: $VULTR_API_ENDPOINT"
echo "API key found (length: ${#VULTR_API_KEY} chars)"

echo "Fetching all VM instances..."
instances_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")

# Define search patterns for BGP instances
primary_pattern="ipv4-bgp-primary"
secondary_pattern="ipv4-bgp-secondary"
tertiary_pattern="ipv4-bgp-tertiary"
ipv6_pattern="ipv6-bgp"

# Function to extract instances with specific pattern
extract_instances() {
  local pattern=$1
  local title=$2
  
  echo -e "\n--- $title Instances ---"
  echo "$instances_response" | grep -o "{[^}]*$pattern[^}]*}" | while read -r instance; do
    id=$(echo "$instance" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    label=$(echo "$instance" | grep -o '"label":"[^"]*' | cut -d'"' -f4)
    date=$(echo "$instance" | grep -o '"date_created":"[^"]*' | cut -d'"' -f4)
    ip=$(echo "$instance" | grep -o '"main_ip":"[^"]*' | cut -d'"' -f4)
    region=$(echo "$instance" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
    
    echo "ID: $id | Region: $region | IP: $ip | Created: $date | Label: $label"
  done | sort -k8
}

# Extract and display instances for each pattern
extract_instances "$primary_pattern" "Primary (ewr) IPv4 BGP"
extract_instances "$secondary_pattern" "Secondary (mia) IPv4 BGP"
extract_instances "$tertiary_pattern" "Tertiary (ord) IPv4 BGP"
extract_instances "$ipv6_pattern" "IPv6 (lax) BGP"

echo -e "\n--- How to Identify Duplicates ---"
echo "1. For each category above, sort by creation date."
echo "2. KEEP the OLDEST instance in each category (one per category)."
echo "3. DELETE all newer instances (these are the duplicates)."
echo
echo "--- How to Delete Duplicates ---"
echo "Execute the following for each duplicate instance ID:"
echo "curl -s -X DELETE \"${VULTR_API_ENDPOINT}instances/YOUR_INSTANCE_ID\" \\"
echo "  -H \"Authorization: Bearer \$VULTR_API_KEY\""