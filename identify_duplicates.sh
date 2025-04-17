#!/bin/bash

# Source .env file to get API credentials 
source "$(dirname "$0")/.env"

# Get all instances
echo "Fetching all BGP instances..."
instances_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")

# Debug - show raw response
echo "Raw API Response (first 300 chars):"
echo "${instances_response:0:300}..."
echo

# Also get and show reserved IPs to help identify quota issues
echo -e "\n--- Reserved IPs ---"
reserved_ips_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")

# Count the IPs
TOTAL_IPS=$(echo "$reserved_ips_response" | grep -o '"id":"[^"]*' | wc -l || echo 0)
echo "Found $TOTAL_IPS reserved IPs (quota includes both active AND recently deleted IPs)"

# Display reserved IPs
if [ "$TOTAL_IPS" -gt 0 ] && [ -n "$reserved_ips_response" ] && ! echo "$reserved_ips_response" | grep -q "error"; then
  # Find all IPs
  echo "$reserved_ips_response" | grep -o "{[^}]*}" | while read -r ip_data; do
    # Skip empty data
    [ -z "$ip_data" ] && continue
    
    ID=$(echo "$ip_data" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    IP=$(echo "$ip_data" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
    REGION=$(echo "$ip_data" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
    
    # Check if instance_id exists and is not null
    if echo "$ip_data" | grep -q '"instance_id":null' || ! echo "$ip_data" | grep -q '"instance_id"'; then
      echo "Unattached IP: $IP (ID: $ID, Region: $REGION)"
    else
      INSTANCE_ID=$(echo "$ip_data" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4)
      echo "Attached IP: $IP (ID: $ID, Region: $REGION, Instance: $INSTANCE_ID)"
    fi
  done
else
  echo "No reserved IPs found or error in API response."
fi

# Parse and display instances by label pattern, sorted by creation date
echo -e "\n--- Primary BGP Instances ---"
echo "$instances_response" | jq -r '.instances[] | select(.label | test("-ipv4-bgp-primary")) | "ID: \(.id) | Created: \(.date_created) | Label: \(.label) | IP: \(.main_ip)"' | sort -k4

echo -e "\n--- Secondary BGP Instances ---"
echo "$instances_response" | jq -r '.instances[] | select(.label | test("-ipv4-bgp-secondary")) | "ID: \(.id) | Created: \(.date_created) | Label: \(.label) | IP: \(.main_ip)"' | sort -k4

echo -e "\n--- Tertiary BGP Instances ---"
echo "$instances_response" | jq -r '.instances[] | select(.label | test("-ipv4-bgp-tertiary")) | "ID: \(.id) | Created: \(.date_created) | Label: \(.label) | IP: \(.main_ip)"' | sort -k4

echo -e "\n--- IPv6 BGP Instances ---"
echo "$instances_response" | jq -r '.instances[] | select(.label | test("-ipv6-bgp")) | "ID: \(.id) | Created: \(.date_created) | Label: \(.label) | IP: \(.main_ip)"' | sort -k4

echo -e "\n--- Recommended Actions ---"
echo "For each group above, keep the OLDEST instance and delete the NEWER ones (duplicates)."
echo "Use the script cleanup_duplicates.sh to delete specific instances by ID."
echo
echo "IMPORTANT: Even after deleting reserved IPs, Vultr maintains a quota that includes"
echo "recently deleted IPs. You may need to wait 24+ hours for the quota to fully reset"
echo "before creating new reserved IPs."
