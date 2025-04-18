#!/bin/bash

source /home/normtodd/birdbgp/deploy.sh source_vars

echo "API key length: ${#VULTR_API_KEY} characters"

# List all instances
echo "Listing all VM instances..."

instances_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")

echo "$instances_response" | grep -A3 -B3 'bgp'