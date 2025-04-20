#!/bin/bash
# Script to update DNS records from anycast IP to floating IP
# Based on dns_create_working.sh

# Load API credentials from .env
source "$(dirname "$0")/.env"

# Configuration
API_KEY="${DNS_API_KEY}"
SECRET_KEY="${DNS_API_SECRET}"
DOMAIN="${DOMAIN:-infinitum-nihil.com}"
FLOATING_IPV4="45.76.76.125"  # LAX server floating IP

echo "Updating DNS records for $DOMAIN"
echo "API Key: $API_KEY"
echo "Floating IPv4: $FLOATING_IPV4"
echo "Changing 'lg' subdomain to point to the floating IP instead of anycast IP"

# Get domain ID directly
echo "Getting domain ID for $DOMAIN..."
REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
HMAC=$(echo -n "${REQUEST_DATE}" | openssl dgst -sha1 -hmac "${SECRET_KEY}" | sed 's/^.* //')

# Get the domain directly instead of using search
DOMAIN_RESPONSE=$(curl -s -X GET \
  -H "x-dnsme-apiKey: $API_KEY" \
  -H "x-dnsme-requestdate: $REQUEST_DATE" \
  -H "x-dnsme-hmac: $HMAC" \
  "https://api.dnsmadeeasy.com/V2.0/dns/managed")

# Extract the domain ID for our specific domain
DOMAIN_ID=$(echo "$DOMAIN_RESPONSE" | jq -r '.data[] | select(.name=="infinitum-nihil.com") | .id')

if [ -z "$DOMAIN_ID" ] || [ "$DOMAIN_ID" = "null" ]; then
  echo "Failed to get domain ID from response. Full response:"
  echo "$DOMAIN_RESPONSE"
  exit 1
fi

echo "Domain ID: $DOMAIN_ID"

# Update the A record for lg subdomain
update_record() {
  local NAME=$1
  local TYPE=$2
  local VALUE=$3
  local TTL=300
  
  echo "Updating $TYPE record: $NAME.$DOMAIN -> $VALUE"
  
  # Check if record exists
  REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
  HMAC=$(echo -n "${REQUEST_DATE}" | openssl dgst -sha1 -hmac "${SECRET_KEY}" | sed 's/^.* //')
  
  RECORD_RESPONSE=$(curl -s -X GET \
    -H "x-dnsme-apiKey: $API_KEY" \
    -H "x-dnsme-requestdate: $REQUEST_DATE" \
    -H "x-dnsme-hmac: $HMAC" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed/$DOMAIN_ID/records?type=$TYPE&recordName=$NAME")
  
  echo "Record search response: $RECORD_RESPONSE"
  RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.data[0].id')
  
  # Prepare record data
  RECORD_DATA="{\"name\":\"$NAME\",\"type\":\"$TYPE\",\"value\":\"$VALUE\",\"ttl\":$TTL}"
  
  if [ -n "$RECORD_ID" ] && [ "$RECORD_ID" != "null" ]; then
    # Update existing record
    echo "Record exists (ID: $RECORD_ID), updating..."
    
    REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
    HMAC=$(echo -n "${REQUEST_DATE}" | openssl dgst -sha1 -hmac "${SECRET_KEY}" | sed 's/^.* //')
    
    UPDATE_RESPONSE=$(curl -s -X PUT \
      -H "x-dnsme-apiKey: $API_KEY" \
      -H "x-dnsme-requestdate: $REQUEST_DATE" \
      -H "x-dnsme-hmac: $HMAC" \
      -H "Content-Type: application/json" \
      -d "$RECORD_DATA" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/$DOMAIN_ID/records/$RECORD_ID")
    
    echo "Update response: $UPDATE_RESPONSE"
    if echo "$UPDATE_RESPONSE" | grep -q "error"; then
      echo "Failed to update record: $UPDATE_RESPONSE"
      return 1
    else
      echo "Record updated successfully"
      return 0
    fi
  else
    # Create new record
    echo "Record doesn't exist, creating new record..."
    
    REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
    HMAC=$(echo -n "${REQUEST_DATE}" | openssl dgst -sha1 -hmac "${SECRET_KEY}" | sed 's/^.* //')
    
    CREATE_RESPONSE=$(curl -s -X POST \
      -H "x-dnsme-apiKey: $API_KEY" \
      -H "x-dnsme-requestdate: $REQUEST_DATE" \
      -H "x-dnsme-hmac: $HMAC" \
      -H "Content-Type: application/json" \
      -d "$RECORD_DATA" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/$DOMAIN_ID/records")
    
    echo "Create response: $CREATE_RESPONSE"
    if echo "$CREATE_RESPONSE" | grep -q "error"; then
      echo "Failed to create record: $CREATE_RESPONSE"
      return 1
    else
      echo "Record created successfully"
      return 0
    fi
  fi
}

# Update just the A record for lg subdomain
update_record "lg" "A" "$FLOATING_IPV4"

echo -e "\nDNS record update completed."
echo "DNS propagation may take up to 24 hours, but often completes within minutes."
echo "You can verify the record using: host lg.$DOMAIN"
