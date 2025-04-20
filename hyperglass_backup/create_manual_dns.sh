#!/bin/bash
# Script to manually create DNS records via API key

# Source environment variables
source "$(dirname "$0")/.env"

# Configuration
DOMAIN=${DOMAIN:-"infinitum-nihil.com"}
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"
DNS_API_KEY=${DNS_API_KEY}
DNS_API_SECRET=${DNS_API_SECRET}

# Test if environment variables are loaded correctly
echo "Domain: $DOMAIN"
echo "API Key: $DNS_API_KEY"
if [ -z "$DNS_API_SECRET" ]; then
  echo "DNS_API_SECRET is not set. Please check your .env file."
  exit 1
fi

# Set proper timestamp format - trying both formats
echo "Testing API connection with different timestamp formats..."

# Try ISO8601 format
ISO_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
ISO_SIGNATURE=$(echo -n "${ISO_TIMESTAMP}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
ISO_RESPONSE=$(curl -s -X GET \
  -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
  -H "x-dnsme-requestDate: ${ISO_TIMESTAMP}" \
  -H "x-dnsme-hmac: ${ISO_SIGNATURE}" \
  "https://api.dnsmadeeasy.com/V2.0/dns/managed")

# Try RFC1123 format
RFC_TIMESTAMP=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
RFC_SIGNATURE=$(echo -n "${RFC_TIMESTAMP}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
RFC_RESPONSE=$(curl -s -X GET \
  -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
  -H "x-dnsme-requestDate: ${RFC_TIMESTAMP}" \
  -H "x-dnsme-hmac: ${RFC_SIGNATURE}" \
  "https://api.dnsmadeeasy.com/V2.0/dns/managed")

# Check which format worked
if ! echo "${ISO_RESPONSE}" | grep -q "error"; then
  echo "ISO8601 format worked!"
  TIMESTAMP_FORMAT="ISO8601"
  API_RESPONSE=$ISO_RESPONSE
elif ! echo "${RFC_RESPONSE}" | grep -q "error"; then
  echo "RFC1123 format worked!"
  TIMESTAMP_FORMAT="RFC1123"
  API_RESPONSE=$RFC_RESPONSE
else
  echo "Both timestamp formats failed. Showing responses:"
  echo "ISO8601 response: $ISO_RESPONSE"
  echo "RFC1123 response: $RFC_RESPONSE"
  
  echo ""
  echo "Checking direct access to API using curl..."
  RESPONSE=$(curl -s "https://api.dnsmadeeasy.com")
  echo "Direct API access response: $RESPONSE"
  
  echo ""
  echo "Please create the DNS records manually:"
  echo "1. Create A record 'lg.$DOMAIN' pointing to $ANYCAST_IPV4"
  echo "2. Create AAAA record 'lg.$DOMAIN' pointing to $ANYCAST_IPV6"
  exit 1
fi

# Function to generate the timestamp based on the working format
get_timestamp() {
  if [ "$TIMESTAMP_FORMAT" = "ISO8601" ]; then
    date -u +"%Y-%m-%dT%H:%M:%S.000Z"
  else
    date -u "+%a, %d %b %Y %H:%M:%S GMT"
  fi
}

# Function to get domain ID
get_domain_id() {
  TIMESTAMP=$(get_timestamp)
  SIGNATURE=$(echo -n "${TIMESTAMP}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
  
  DOMAIN_RESPONSE=$(curl -s -X GET \
    -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
    -H "x-dnsme-requestDate: ${TIMESTAMP}" \
    -H "x-dnsme-hmac: ${SIGNATURE}" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed/name?domainname=${DOMAIN}")
  
  echo "$DOMAIN_RESPONSE" | jq -r '.data[0].id'
}

# Function to create or update a DNS record
create_record() {
  local name=$1
  local type=$2
  local value=$3
  local domain_id=$4
  local ttl=300
  
  echo "Creating $type record for $name.$DOMAIN pointing to $value..."
  
  # Check if record exists
  TIMESTAMP=$(get_timestamp)
  SIGNATURE=$(echo -n "${TIMESTAMP}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
  
  EXISTING=$(curl -s -X GET \
    -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
    -H "x-dnsme-requestDate: ${TIMESTAMP}" \
    -H "x-dnsme-hmac: ${SIGNATURE}" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records?type=${type}&recordName=${name}")
  
  RECORD_ID=$(echo "$EXISTING" | jq -r '.data[0].id')
  
  # Create payload
  JSON="{\"name\":\"${name}\",\"type\":\"${type}\",\"value\":\"${value}\",\"ttl\":${ttl}}"
  
  TIMESTAMP=$(get_timestamp)
  SIGNATURE=$(echo -n "${TIMESTAMP}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
  
  if [ -n "$RECORD_ID" ] && [ "$RECORD_ID" != "null" ]; then
    echo "Record exists with ID $RECORD_ID, updating..."
    RESPONSE=$(curl -s -X PUT \
      -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
      -H "x-dnsme-requestDate: ${TIMESTAMP}" \
      -H "x-dnsme-hmac: ${SIGNATURE}" \
      -H "Content-Type: application/json" \
      -d "$JSON" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records/${RECORD_ID}")
  else
    echo "Creating new record..."
    RESPONSE=$(curl -s -X POST \
      -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
      -H "x-dnsme-requestDate: ${TIMESTAMP}" \
      -H "x-dnsme-hmac: ${SIGNATURE}" \
      -H "Content-Type: application/json" \
      -d "$JSON" \
      "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records/")
  fi
  
  if echo "$RESPONSE" | grep -q "error"; then
    echo "Failed to create/update record: $RESPONSE"
    return 1
  else
    echo "Successfully created/updated record!"
    return 0
  fi
}

# Get domain ID
echo "Getting domain ID for $DOMAIN..."
DOMAIN_ID=$(get_domain_id)

if [ -z "$DOMAIN_ID" ] || [ "$DOMAIN_ID" = "null" ]; then
  echo "Failed to get domain ID. Please create the DNS records manually:"
  echo "1. Create A record 'lg.$DOMAIN' pointing to $ANYCAST_IPV4"
  echo "2. Create AAAA record 'lg.$DOMAIN' pointing to $ANYCAST_IPV6"
  exit 1
fi

echo "Domain ID: $DOMAIN_ID"

# Create records
create_record "lg" "A" "$ANYCAST_IPV4" "$DOMAIN_ID"
create_record "lg" "AAAA" "$ANYCAST_IPV6" "$DOMAIN_ID"

echo "DNS record creation completed."
echo "Note: DNS propagation may take up to 24 hours."