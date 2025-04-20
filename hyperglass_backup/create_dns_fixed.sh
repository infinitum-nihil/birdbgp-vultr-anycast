#!/bin/bash
# Script to create DNS records with DNSMadeEasy API using correct HMAC generation

# Source environment variables
source "$(dirname "$0")/.env"

# Configuration
DOMAIN=${DOMAIN:-"infinitum-nihil.com"}
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"
DNS_API_KEY=${DNS_API_KEY}
DNS_API_SECRET=${DNS_API_SECRET}
TTL=300

echo "Creating DNS records for $DOMAIN"
echo "API Key: $DNS_API_KEY"
echo "Anycast IPv4: $ANYCAST_IPV4"
echo "Anycast IPv6: $ANYCAST_IPV6"

# First, get the domain ID
get_domain_id() {
  echo "Getting domain ID for $DOMAIN..."
  
  # Generate date in required format
  DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
  
  # Generate HMAC signature including HTTP method
  SIGNATURE=$(echo -n "GET$DATE" | openssl dgst -sha1 -hmac "$DNS_API_SECRET" | sed 's/^.* //')
  
  # Make API request
  RESPONSE=$(curl -s -X GET \
    -H "x-dnsme-apiKey: $DNS_API_KEY" \
    -H "x-dnsme-requestDate: $DATE" \
    -H "x-dnsme-hmac: $SIGNATURE" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed/name?domainname=$DOMAIN")
  
  # Check for error
  if echo "$RESPONSE" | grep -q "error"; then
    echo "Error getting domain ID: $RESPONSE"
    return 1
  fi
  
  # Extract domain ID
  DOMAIN_ID=$(echo "$RESPONSE" | jq -r '.data[0].id')
  
  if [ -z "$DOMAIN_ID" ] || [ "$DOMAIN_ID" = "null" ]; then
    echo "Could not find domain ID for $DOMAIN"
    return 1
  fi
  
  echo "Domain ID: $DOMAIN_ID"
  echo "$DOMAIN_ID"
}

# Create a DNS record
create_record() {
  local name=$1
  local type=$2
  local value=$3
  local domain_id=$4
  
  echo "Creating $type record for $name.$DOMAIN pointing to $value..."
  
  # First check if record exists
  DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
  SIGNATURE=$(echo -n "GET$DATE" | openssl dgst -sha1 -hmac "$DNS_API_SECRET" | sed 's/^.* //')
  
  EXISTING_RESPONSE=$(curl -s -X GET \
    -H "x-dnsme-apiKey: $DNS_API_KEY" \
    -H "x-dnsme-requestDate: $DATE" \
    -H "x-dnsme-hmac: $SIGNATURE" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed/$domain_id/records?type=$type&recordName=$name")
  
  # Check for existing record
  RECORD_ID=$(echo "$EXISTING_RESPONSE" | jq -r '.data[0].id')
  
  # Create JSON payload
  DATA='{
    "name": "'"$name"'",
    "type": "'"$type"'",
    "value": "'"$value"'",
    "ttl": '"$TTL"'
  }'
  
  # If record exists, update it
  if [ -n "$RECORD_ID" ] && [ "$RECORD_ID" != "null" ]; then
    echo "Record exists with ID $RECORD_ID, updating..."
    
    # Generate date and signature for PUT request
    DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
    SIGNATURE=$(echo -n "PUT$DATE" | openssl dgst -sha1 -hmac "$DNS_API_SECRET" | sed 's/^.* //')
    
    # Make API request
    RESPONSE=$(curl -s -X PUT \
      -H "x-dnsme-apiKey: $DNS_API_KEY" \
      -H "x-dnsme-requestDate: $DATE" \
      -H "x-dnsme-hmac: $SIGNATURE" \
      -H "Content-Type: application/json" \
      -d "$DATA" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/$domain_id/records/$RECORD_ID")
  else
    # Create new record
    echo "Creating new record..."
    
    # Generate date and signature for POST request
    DATE=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
    SIGNATURE=$(echo -n "POST$DATE" | openssl dgst -sha1 -hmac "$DNS_API_SECRET" | sed 's/^.* //')
    
    # Make API request
    RESPONSE=$(curl -s -X POST \
      -H "x-dnsme-apiKey: $DNS_API_KEY" \
      -H "x-dnsme-requestDate: $DATE" \
      -H "x-dnsme-hmac: $SIGNATURE" \
      -H "Content-Type: application/json" \
      -d "$DATA" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/$domain_id/records")
  fi
  
  # Check for error
  if echo "$RESPONSE" | grep -q "error"; then
    echo "Error creating/updating record: $RESPONSE"
    return 1
  else
    echo "Successfully created/updated record!"
    return 0
  fi
}

# Get domain ID
DOMAIN_ID=$(get_domain_id)
if [ $? -ne 0 ]; then
  echo "Failed to get domain ID. Please check your API credentials."
  exit 1
fi

# Create records
create_record "lg" "A" "$ANYCAST_IPV4" "$DOMAIN_ID"
create_record "lg" "AAAA" "$ANYCAST_IPV6" "$DOMAIN_ID"

echo "DNS record creation completed. Records may take up to 24 hours to propagate."
echo "You can verify the records using the command: host lg.$DOMAIN"