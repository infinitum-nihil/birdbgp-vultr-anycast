#!/bin/bash
# Script to create DNS records with DNSMadeEasy API
# Uses a different approach for HMAC calculation

# Load API credentials from .env
source "$(dirname "$0")/.env"

# Configuration
API_KEY="${DNS_API_KEY}"
SECRET_KEY="${DNS_API_SECRET}"
DOMAIN="${DOMAIN:-infinitum-nihil.com}"
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"

echo "Creating DNS records for $DOMAIN"
echo "API Key: $API_KEY"
echo "Secret Key: ****${SECRET_KEY:(-8)}" # Show only last 8 characters for security
echo "Anycast IPv4: $ANYCAST_IPV4"
echo "Anycast IPv6: $ANYCAST_IPV6"

# Convert secret key from UUID format to hex
# Replace hyphens and convert to lowercase
SECRET_HEX=$(echo "$SECRET_KEY" | tr -d '-' | tr '[:upper:]' '[:lower:]')
echo "Using hex secret: ${SECRET_HEX:0:8}...${SECRET_HEX:(-8)}"

# Test API connection with different HMAC format
test_api() {
  # Generate request date
  REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
  
  # Generate HMAC signature with hex secret
  HMAC=$(echo -n "GET${REQUEST_DATE}" | openssl dgst -sha1 -hmac "$SECRET_HEX" | cut -d ' ' -f2)
  
  echo "Date: $REQUEST_DATE"
  echo "HMAC: $HMAC"
  
  # Make request to list domains
  RESPONSE=$(curl -v -X GET \
    -H "x-dnsme-apiKey: $API_KEY" \
    -H "x-dnsme-requestDate: $REQUEST_DATE" \
    -H "x-dnsme-hmac: $HMAC" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed" 2>&1)
  
  echo "$RESPONSE"
}

echo "Testing API connection..."
API_TEST=$(test_api)

if echo "$API_TEST" | grep -q "error"; then
  echo "API test failed with regular format. Full response:"
  echo "$API_TEST"
  
  echo -e "\n==============================================="
  echo "Please add these DNS records manually:"
  echo "1. A record: lg.$DOMAIN -> $ANYCAST_IPV4"
  echo "2. AAAA record: lg.$DOMAIN -> $ANYCAST_IPV6"
  echo "==============================================="
  exit 1
fi

# If we reach here, API connection was successful
echo "API connection successful!"

# Get domain ID
echo "Getting domain ID for $DOMAIN..."
REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
HMAC=$(echo -n "GET${REQUEST_DATE}" | openssl dgst -sha1 -hmac "$SECRET_HEX" | cut -d ' ' -f2)

DOMAIN_RESPONSE=$(curl -s -X GET \
  -H "x-dnsme-apiKey: $API_KEY" \
  -H "x-dnsme-requestDate: $REQUEST_DATE" \
  -H "x-dnsme-hmac: $HMAC" \
  "https://api.dnsmadeeasy.com/V2.0/dns/managed/name?domainname=$DOMAIN")

DOMAIN_ID=$(echo "$DOMAIN_RESPONSE" | jq -r '.data[0].id')

if [ -z "$DOMAIN_ID" ] || [ "$DOMAIN_ID" = "null" ]; then
  echo "Failed to get domain ID: $DOMAIN_RESPONSE"
  
  echo -e "\n==============================================="
  echo "Please add these DNS records manually:"
  echo "1. A record: lg.$DOMAIN -> $ANYCAST_IPV4"
  echo "2. AAAA record: lg.$DOMAIN -> $ANYCAST_IPV6"
  echo "==============================================="
  exit 1
fi

echo "Domain ID: $DOMAIN_ID"

# Function to create/update record
create_record() {
  local NAME=$1
  local TYPE=$2
  local VALUE=$3
  local TTL=300
  
  echo "Creating $TYPE record: $NAME.$DOMAIN -> $VALUE"
  
  # Check if record exists
  REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
  HMAC=$(echo -n "GET${REQUEST_DATE}" | openssl dgst -sha1 -hmac "$SECRET_HEX" | cut -d ' ' -f2)
  
  RECORD_RESPONSE=$(curl -s -X GET \
    -H "x-dnsme-apiKey: $API_KEY" \
    -H "x-dnsme-requestDate: $REQUEST_DATE" \
    -H "x-dnsme-hmac: $HMAC" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed/$DOMAIN_ID/records?type=$TYPE&recordName=$NAME")
  
  RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.data[0].id')
  
  # Prepare record data
  RECORD_DATA="{\"name\":\"$NAME\",\"type\":\"$TYPE\",\"value\":\"$VALUE\",\"ttl\":$TTL,\"gtdLocation\":\"DEFAULT\"}"
  
  if [ -n "$RECORD_ID" ] && [ "$RECORD_ID" != "null" ]; then
    # Update existing record
    echo "Record exists (ID: $RECORD_ID), updating..."
    
    REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
    HMAC=$(echo -n "PUT${REQUEST_DATE}" | openssl dgst -sha1 -hmac "$SECRET_HEX" | cut -d ' ' -f2)
    
    UPDATE_RESPONSE=$(curl -s -X PUT \
      -H "x-dnsme-apiKey: $API_KEY" \
      -H "x-dnsme-requestDate: $REQUEST_DATE" \
      -H "x-dnsme-hmac: $HMAC" \
      -H "Content-Type: application/json" \
      -d "$RECORD_DATA" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/$DOMAIN_ID/records/$RECORD_ID")
    
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
    HMAC=$(echo -n "POST${REQUEST_DATE}" | openssl dgst -sha1 -hmac "$SECRET_HEX" | cut -d ' ' -f2)
    
    CREATE_RESPONSE=$(curl -s -X POST \
      -H "x-dnsme-apiKey: $API_KEY" \
      -H "x-dnsme-requestDate: $REQUEST_DATE" \
      -H "x-dnsme-hmac: $HMAC" \
      -H "Content-Type: application/json" \
      -d "$RECORD_DATA" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/$DOMAIN_ID/records")
    
    if echo "$CREATE_RESPONSE" | grep -q "error"; then
      echo "Failed to create record: $CREATE_RESPONSE"
      return 1
    else
      echo "Record created successfully"
      return 0
    fi
  fi
}

# Create A and AAAA records
create_record "lg" "A" "$ANYCAST_IPV4"
create_record "lg" "AAAA" "$ANYCAST_IPV6"

echo -e "\nDNS record creation attempt completed."
echo "If the script reported success, DNS propagation may take up to 24 hours."
echo "You can verify records using: host lg.$DOMAIN"
