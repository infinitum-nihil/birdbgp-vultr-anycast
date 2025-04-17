#!/bin/bash

# Source .env file to get API credentials
source "$(dirname "$0")/.env"

# IMPORTANT: Vultr has a quota limit for reserved IPs that includes both active AND recently deleted IPs
# Deleting IPs will not immediately free up quota - Vultr has a cooldown period (likely 24+ hours)
# before recently deleted IPs stop counting against your quota.
# Running this script when at quota limit will not immediately allow new IP creation.

# Get all reserved IPs
echo "Fetching all reserved IPs..."
RESERVED_IPS=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")

# Count the IPs
TOTAL_IPS=$(echo "$RESERVED_IPS" | grep -o '"id":"[^"]*' | wc -l || echo 0)
echo "Found $TOTAL_IPS reserved IPs"

# IP deletion tracking file
IP_TRACKING_FILE="$(dirname "$0")/reserved_ip_deletions.log"
touch "$IP_TRACKING_FILE"

# Record deletion for quota management tracking
record_ip_deletion() {
  local ip=$1
  local id=$2
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "$timestamp | DELETED | $id | $ip" >> "$IP_TRACKING_FILE"
  echo "Recorded deletion in $IP_TRACKING_FILE for future quota management"
}

# Check if we have response data before trying to parse
if [ "$TOTAL_IPS" -gt 0 ] && [ -n "$RESERVED_IPS" ] && ! echo "$RESERVED_IPS" | grep -q "error"; then
  # Find unattached IPs
  echo "Checking for unattached IPs..."
  echo "$RESERVED_IPS" | grep -o "{[^}]*}" | while read -r ip_data; do
    # Skip empty data
    [ -z "$ip_data" ] && continue
    
    ID=$(echo "$ip_data" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    IP=$(echo "$ip_data" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
    REGION=$(echo "$ip_data" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
    
    # Skip if we couldn't get ID
    [ -z "$ID" ] && continue
    
    # Check if instance_id exists and is not null
    if echo "$ip_data" | grep -q '"instance_id":null' || ! echo "$ip_data" | grep -q '"instance_id"'; then
      echo "Found unattached IP: $IP (ID: $ID, Region: $REGION)"
      
      # Delete the unattached IP
      echo "Deleting unattached IP $IP..."
      DELETE_RESPONSE=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}reserved-ips/$ID" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
      
      if [ -z "$DELETE_RESPONSE" ]; then
        echo "✅ Successfully deleted reserved IP $IP"
        record_ip_deletion "$IP" "$ID"
      else
        echo "❌ Failed to delete reserved IP: $DELETE_RESPONSE"
      fi
      
      # Wait to avoid API rate limits
      sleep 3
    fi
  done
else
  echo "No reserved IPs found or error in API response. Nothing to clean up."
fi

echo "Cleanup completed!"
echo "WARNING: Vultr maintains a quota that includes recently deleted IPs."
echo "You may need to wait 24+ hours for the quota to reset before you can create new IPs."
echo "If you need immediate capacity, contact Vultr support for a quota increase."
echo "You can review deletion history in: $IP_TRACKING_FILE"