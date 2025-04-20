#!/bin/bash

# Load environment variables
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo "Loaded environment variables from $ENV_FILE"
else
    echo "Error: Environment file not found: $ENV_FILE"
    exit 1
fi

# DNS API variables
DNS_PROVIDER=${DNS_PROVIDER}
DNS_API_KEY=${DNS_API_KEY}
DNS_API_SECRET=${DNS_API_SECRET}
DOMAIN=${DOMAIN}

# Anycast IP (the floating IP)
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"

# Text formatting
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# Function to create a DNS record using DNSMadeEasy API
create_dnsmadeeasy_record() {
    local name=$1
    local type=$2
    local value=$3
    local ttl=${4:-3600}

    echo "Creating ${type} record for ${name}.${DOMAIN} pointing to ${value}..."

    # Current timestamp for request header
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    
    # Generate HMAC signature
    data="${timestamp}:${DNS_API_KEY}"
    signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    # Find domain ID first
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
    
    # Check if record already exists
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    data="${timestamp}:${DNS_API_KEY}"
    signature=$(echo -n "${data}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    existing_record=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${timestamp}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records?name=${name}")
    
    existing_id=$(echo "${existing_record}" | jq -r '.data[0].id')
    
    # Create JSON payload
    json_payload="{\"name\":\"${name}\",\"type\":\"${type}\",\"value\":\"${value}\",\"ttl\":${ttl}}"
    
    # If record exists, update it
    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        echo "Record already exists with ID ${existing_id}, updating..."
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        data="${timestamp}:${DNS_API_KEY}"
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
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        data="${timestamp}:${DNS_API_KEY}"
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
        echo "${response}"
        return 1
    else
        echo -e "${GREEN}Successfully created/updated ${type} record for ${name}.${DOMAIN}${RESET}"
        return 0
    fi
}


# Create A records (IPv4)
create_dnsmadeeasy_record "lg" "A" "${ANYCAST_IPV4}"

# Create AAAA records (IPv6)
create_dnsmadeeasy_record "lg" "AAAA" "${ANYCAST_IPV6}"

echo "DNS record creation completed."