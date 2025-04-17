#!/bin/bash

# Source .env file
source "$(dirname "$0")/.env"

# IDs of duplicate instances to delete (the NEWER ones)
DUPLICATE_IDS=(
  "c6acd96e-b663-41c5-9409-6e3ea9ad5cad"  # Primary duplicate
  "cdc03ae6-f5ef-4463-8864-687367508d81"  # Secondary duplicate
  "f2f48b0c-e561-45fa-8a1f-555b981b7bda"  # Tertiary duplicate
  "4368c381-c8a4-4e76-b030-27a7bd1ad899"  # IPv6 duplicate
)

# Check if we should use provided IDs instead
if [ $# -gt 0 ]; then
  echo "Using provided instance IDs instead of hardcoded ones."
  DUPLICATE_IDS=("$@")
fi

# Delete each instance
for instance_id in "${DUPLICATE_IDS[@]}"; do
  echo "Deleting instance $instance_id..."
  response=$(curl -s -X DELETE "https://api.vultr.com/v2/instances/$instance_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  # Check if successful (API returns 204 No Content for success)
  if [ -z "$response" ]; then
    echo "Successfully deleted instance $instance_id"
  else
    echo "Failed to delete instance $instance_id: $response"
  fi
done

echo "Cleanup complete!"
