#!/bin/bash
# Script to create DNS records with DNSMadeEasy API
# Fixing the HMAC calculation per official documentation

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
echo "Anycast IPv4: $ANYCAST_IPV4"
echo "Anycast IPv6: $ANYCAST_IPV6"

# Test API connection
echo "Testing API connection..."
# Generate request date in HTTP format
REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")

# Calculate the hexadecimal HMAC SHA1 hash of ONLY the timestamp string
# This is the key difference - we don't include the HTTP method
HMAC=$(echo -n "${REQUEST_DATE}" | openssl dgst -sha1 -hmac "${SECRET_KEY}" | sed 's/^.* //')

echo "Date: $REQUEST_DATE"
echo "HMAC: $HMAC"

# Make request to list domains with lowercase 'requestdate'
API_TEST=$(curl -s -X GET \
  -H "x-dnsme-apiKey: $API_KEY" \
  -H "x-dnsme-requestdate: $REQUEST_DATE" \
  -H "x-dnsme-hmac: $HMAC" \
  "https://api.dnsmadeeasy.com/V2.0/dns/managed")

echo "API Response: $API_TEST"

if echo "$API_TEST" | grep -q "error"; then
  echo "API test failed: $API_TEST"
  
  echo -e "\n==============================================="
  echo "Please add these DNS records manually:"
  echo "1. A record: lg.$DOMAIN -> $ANYCAST_IPV4"
  echo "2. AAAA record: lg.$DOMAIN -> $ANYCAST_IPV6"
  echo "==============================================="
  exit 1
fi

echo "API connection successful!"

# Get domain ID
echo "Getting domain ID for $DOMAIN..."
REQUEST_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
HMAC=$(echo -n "${REQUEST_DATE}" | openssl dgst -sha1 -hmac "${SECRET_KEY}" | sed 's/^.* //')

DOMAIN_RESPONSE=$(curl -s -X GET \
  -H "x-dnsme-apiKey: $API_KEY" \
  -H "x-dnsme-requestdate: $REQUEST_DATE" \
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
  HMAC=$(echo -n "${REQUEST_DATE}" | openssl dgst -sha1 -hmac "${SECRET_KEY}" | sed 's/^.* //')
  
  RECORD_RESPONSE=$(curl -s -X GET \
    -H "x-dnsme-apiKey: $API_KEY" \
    -H "x-dnsme-requestdate: $REQUEST_DATE" \
    -H "x-dnsme-hmac: $HMAC" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed/$DOMAIN_ID/records?type=$TYPE&recordName=$NAME")
  
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
