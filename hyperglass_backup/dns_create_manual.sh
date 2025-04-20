#!/bin/bash
# Manual creation of DNS records for the BGP looking glass and Traefik dashboard

# Load environment variables
source "$(dirname "$0")/.env"

# Variables
DOMAIN=${DOMAIN:-"infinitum-nihil.com"}
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"
DNS_PROVIDER=${DNS_PROVIDER:-"dnsmadeeasy"}
DNS_API_KEY=${DNS_API_KEY}
DNS_API_SECRET=${DNS_API_SECRET}

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"

echo "======================================================="
echo -e "Domain: ${DOMAIN}"
echo -e "IPv4 Anycast: ${ANYCAST_IPV4}"
echo -e "IPv6 Anycast: ${ANYCAST_IPV6}"
echo -e "DNS Provider: ${DNS_PROVIDER}"
echo "======================================================="

# Function to create DNSMadeEasy record with ISO8601 timestamp format
create_dnsmadeeasy_record_iso8601() {
    local name=$1
    local type=$2
    local value=$3
    local ttl=${4:-300}  # Default to 5 minutes TTL
    
    echo "Creating ${type} record for ${name}.${DOMAIN} pointing to ${value}..."
    
    # Current timestamp for request header in ISO8601 format
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    
    # Generate HMAC signature
    local data="${timestamp}"
    local signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    # Find domain ID first
    echo "Looking up domain ID for ${DOMAIN}..."
    domain_id_response=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${timestamp}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed/name?domainname=${DOMAIN}")
    
    domain_id=$(echo "${domain_id_response}" | jq -r '.data[0].id')
    
    if [ -z "${domain_id}" ] || [ "${domain_id}" = "null" ]; then
        echo -e "${RED}Failed to get domain ID for ${DOMAIN}${RESET}"
        echo "Response: ${domain_id_response}"
        return 1
    fi
    
    echo "Domain ID: ${domain_id}"
    
    # Check if record already exists
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    data="${timestamp}"
    signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    echo "Checking if record ${name}.${DOMAIN} already exists..."
    existing_record=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${timestamp}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records?recordName=${name}")
    
    echo "Existing record response: ${existing_record}"
    existing_id=$(echo "${existing_record}" | jq -r '.data[] | select(.type == "'"${type}"'") | .id')
    
    # Create JSON payload
    json_payload="{\"name\":\"${name}\",\"type\":\"${type}\",\"value\":\"${value}\",\"ttl\":${ttl}}"
    
    # If record exists, update it
    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        echo "Record already exists with ID ${existing_id}, updating..."
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        data="${timestamp}"
        signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
        
        response=$(curl -s -X PUT \
            -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
            -H "x-dnsme-requestDate: ${timestamp}" \
            -H "x-dnsme-hmac: ${signature}" \
            -H "Content-Type: application/json" \
            -d "${json_payload}" \
            "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records/${existing_id}")
    else
        # Create new record
        echo "Creating new record..."
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        data="${timestamp}"
        signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
        
        response=$(curl -s -X POST \
            -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
            -H "x-dnsme-requestDate: ${timestamp}" \
            -H "x-dnsme-hmac: ${signature}" \
            -H "Content-Type: application/json" \
            -d "${json_payload}" \
            "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records/")
    fi
    
    # Check if successful
    if echo "${response}" | grep -q "error"; then
        echo -e "${RED}Failed to create/update record:${RESET}"
        echo "Response: ${response}"
        return 1
    else
        echo -e "${GREEN}Successfully created/updated ${type} record for ${name}.${DOMAIN}${RESET}"
        return 0
    fi
}

# Function to create DNSMadeEasy record with RFC1123 timestamp format
create_dnsmadeeasy_record_rfc1123() {
    local name=$1
    local type=$2
    local value=$3
    local ttl=${4:-300}  # Default to 5 minutes TTL
    
    echo "Creating ${type} record for ${name}.${DOMAIN} pointing to ${value}..."
    
    # Current timestamp for request header in RFC1123 format
    local timestamp=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
    
    # Generate HMAC signature
    local data="${timestamp}"
    local signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    # Find domain ID first
    echo "Looking up domain ID for ${DOMAIN}..."
    domain_id_response=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${timestamp}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed/name?domainname=${DOMAIN}")
    
    domain_id=$(echo "${domain_id_response}" | jq -r '.data[0].id')
    
    if [ -z "${domain_id}" ] || [ "${domain_id}" = "null" ]; then
        echo -e "${RED}Failed to get domain ID for ${DOMAIN}${RESET}"
        echo "Response: ${domain_id_response}"
        return 1
    fi
    
    echo "Domain ID: ${domain_id}"
    
    # Check if record already exists
    timestamp=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
    data="${timestamp}"
    signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    echo "Checking if record ${name}.${DOMAIN} already exists..."
    existing_record=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${timestamp}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records?recordName=${name}")
    
    echo "Existing record response: ${existing_record}"
    existing_id=$(echo "${existing_record}" | jq -r '.data[] | select(.type == "'"${type}"'") | .id')
    
    # Create JSON payload
    json_payload="{\"name\":\"${name}\",\"type\":\"${type}\",\"value\":\"${value}\",\"ttl\":${ttl}}"
    
    # If record exists, update it
    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        echo "Record already exists with ID ${existing_id}, updating..."
        timestamp=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
        data="${timestamp}"
        signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
        
        response=$(curl -s -X PUT \
            -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
            -H "x-dnsme-requestDate: ${timestamp}" \
            -H "x-dnsme-hmac: ${signature}" \
            -H "Content-Type: application/json" \
            -d "${json_payload}" \
            "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records/${existing_id}")
    else
        # Create new record
        echo "Creating new record..."
        timestamp=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
        data="${timestamp}"
        signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
        
        response=$(curl -s -X POST \
            -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
            -H "x-dnsme-requestDate: ${timestamp}" \
            -H "x-dnsme-hmac: ${signature}" \
            -H "Content-Type: application/json" \
            -d "${json_payload}" \
            "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records/")
    fi
    
    # Check if successful
    if echo "${response}" | grep -q "error"; then
        echo -e "${RED}Failed to create/update record:${RESET}"
        echo "Response: ${response}"
        return 1
    else
        echo -e "${GREEN}Successfully created/updated ${type} record for ${name}.${DOMAIN}${RESET}"
        return 0
    fi
}

# First, test API status before attempting to create records
echo "Testing DNSMadeEasy API connection..."
timestamp=$(date -u "+%Y-%m-%dT%H:%M:%S.000Z")
data="${timestamp}"
signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)

response=$(curl -s -X GET \
    -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
    -H "x-dnsme-requestDate: ${timestamp}" \
    -H "x-dnsme-hmac: ${signature}" \
    "https://api.dnsmadeeasy.com/V2.0/dns/managed")

if [ $? -ne 0 ] || echo "${response}" | grep -q "error"; then
    echo -e "${RED}API test failed with ISO8601 format. Trying RFC1123 format...${RESET}"
    
    # Try with RFC1123 format
    timestamp=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
    data="${timestamp}"
    signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    response=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${timestamp}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed")
    
    if [ $? -ne 0 ] || echo "${response}" | grep -q "error"; then
        echo -e "${RED}API tests failed with both timestamp formats. Cannot proceed.${RESET}"
        echo "Response: ${response}"
        exit 1
    else
        echo -e "${GREEN}API test successful with RFC1123 format!${RESET}"
        USE_RFC1123=true
    fi
else
    echo -e "${GREEN}API test successful with ISO8601 format!${RESET}"
    USE_RFC1123=false
fi

if [ "$USE_RFC1123" = true ]; then
    echo "Using RFC1123 date format for API calls..."
    # Create A records (IPv4)
    create_dnsmadeeasy_record_rfc1123 "lg" "A" "${ANYCAST_IPV4}"
    
    # Create AAAA records (IPv6)
    create_dnsmadeeasy_record_rfc1123 "lg" "AAAA" "${ANYCAST_IPV6}"
else
    echo "Using ISO8601 date format for API calls..."
    # Create A records (IPv4)
    create_dnsmadeeasy_record_iso8601 "lg" "A" "${ANYCAST_IPV4}"
    
    # Create AAAA records (IPv6)
    create_dnsmadeeasy_record_iso8601 "lg" "AAAA" "${ANYCAST_IPV6}"
fi

echo -e "${GREEN}DNS record creation completed.${RESET}"
echo "=========================================="
echo -e "Records created or updated:"
echo -e "- lg.${DOMAIN} -> ${ANYCAST_IPV4} (A)"
echo -e "- lg.${DOMAIN} -> ${ANYCAST_IPV6} (AAAA)"
echo "=========================================="
echo -e "${YELLOW}Note: DNS propagation may take up to 24 hours.${RESET}"