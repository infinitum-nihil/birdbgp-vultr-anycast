#!/bin/bash

# Load environment variables
source "$(dirname "$0")/.env"

# Get current date in RFC 1123 format
requestDate=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')

# Debug info
echo "API Key: ${DNS_API_KEY}"
echo "API Secret: ${DNS_API_SECRET}"
echo "Domain: ${DOMAIN}"
echo "Request Date: ${requestDate}"

# Create HMAC signature
data="${requestDate}"
signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)

echo "HMAC Signature: ${signature}"

# Make API request
response=$(curl -s -X GET \
    -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
    -H "x-dnsme-requestDate: ${requestDate}" \
    -H "x-dnsme-hmac: ${signature}" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed")

echo "API Response:"
echo "${response}"