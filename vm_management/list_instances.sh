#!/bin/bash

# Extract API credentials from the deploy.sh script
VULTR_API_KEY=$(grep -o 'VULTR_API_KEY=\"[^\"]*\"' /home/normtodd/birdbgp/deploy.sh | head -1 | cut -d'=' -f2 | tr -d '"')
VULTR_API_ENDPOINT="https://api.vultr.com/v2/"

echo "Using API endpoint: $VULTR_API_ENDPOINT"
echo "API key length: ${#VULTR_API_KEY} characters"

# List all instances
echo "Listing all instances..."
curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
  -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -i "bgp\|id\|label\|main_ip\|date_created"