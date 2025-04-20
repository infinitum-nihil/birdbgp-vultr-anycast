#!/bin/bash
# Script to fix DNSMadeEasy API authentication and create required DNS records

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
DNS_API_KEY=${DNS_API_KEY}
DNS_API_SECRET=${DNS_API_SECRET}
DOMAIN=${DOMAIN:-"infinitum-nihil.com"}

# Anycast IP (the floating IP)
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"

# Text formatting
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
BOLD="\033[1m"
RESET="\033[0m"

echo -e "${BOLD}DNSMadeEasy API Authentication Fix${RESET}"
echo "=========================================="
echo -e "API Key: ${BLUE}${DNS_API_KEY}${RESET}"
echo -e "Domain: ${BLUE}${DOMAIN}${RESET}"
echo -e "Anycast IPv4: ${BLUE}${ANYCAST_IPV4}${RESET}"
echo -e "Anycast IPv6: ${BLUE}${ANYCAST_IPV6}${RESET}"
echo "=========================================="

# Function to test API connection
test_api_connection() {
    # Get current date in RFC 1123 format (Thu, 18 Apr 2025 14:12:34 GMT)
    requestDate=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')
    
    # Create HMAC signature using ONLY the timestamp
    signature=$(echo -n "${requestDate}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    echo -e "Testing API with RFC 1123 date format..."
    echo -e "Request Date: ${BLUE}${requestDate}${RESET}"
    echo -e "HMAC Signature: ${BLUE}${signature}${RESET}"
    
    # Make API request
    response=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${requestDate}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed")
    
    if [[ $? -ne 0 || "$response" =~ "error" ]]; then
        echo -e "${RED}API connection test failed${RESET}"
        echo "Response: $response"
        return 1
    else
        echo -e "${GREEN}API connection successful!${RESET}"
        return 0
    fi
}

# Function to get domain ID
get_domain_id() {
    requestDate=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')
    signature=$(echo -n "${requestDate}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    echo -e "Looking up domain ID for ${DOMAIN}..."
    
    domain_id_response=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${requestDate}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed/name?domainname=${DOMAIN}")
    
    if [[ "$domain_id_response" =~ "error" ]]; then
        echo -e "${RED}Failed to get domain ID${RESET}"
        echo "Response: $domain_id_response"
        return 1
    fi
    
    domain_id=$(echo "${domain_id_response}" | jq -r '.data[0].id')
    
    if [ -z "${domain_id}" ] || [ "${domain_id}" = "null" ]; then
        echo -e "${RED}Could not extract domain ID from response${RESET}"
        echo "Response: $domain_id_response"
        return 1
    fi
    
    echo -e "Domain ID: ${GREEN}${domain_id}${RESET}"
    echo "$domain_id"
}

# Function to create or update a DNS record
create_dns_record() {
    local name=$1
    local type=$2
    local value=$3
    local ttl=${4:-300}
    local domain_id=$5
    
    echo -e "\nCreating/updating ${type} record: ${BLUE}${name}.${DOMAIN}${RESET} -> ${BLUE}${value}${RESET}"
    
    # Check if record already exists
    requestDate=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')
    signature=$(echo -n "${requestDate}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
    
    existing_record=$(curl -s -X GET \
        -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
        -H "x-dnsme-requestDate: ${requestDate}" \
        -H "x-dnsme-hmac: ${signature}" \
        "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records?type=${type}&recordName=${name}")
    
    if [[ "$existing_record" =~ "error" ]]; then
        echo -e "${RED}Error checking existing records${RESET}"
        echo "Response: $existing_record"
        return 1
    fi
    
    existing_id=$(echo "${existing_record}" | jq -r '.data[0].id')
    
    # Create JSON payload
    json_payload="{\"name\":\"${name}\",\"type\":\"${type}\",\"value\":\"${value}\",\"ttl\":${ttl}}"
    
    # If record exists, update it
    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        echo "Record exists with ID ${existing_id}, updating..."
        
        requestDate=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')
        signature=$(echo -n "${requestDate}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
        
        response=$(curl -s -X PUT \
            -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
            -H "x-dnsme-requestDate: ${requestDate}" \
            -H "x-dnsme-hmac: ${signature}" \
            -H "Content-Type: application/json" \
            -d "${json_payload}" \
            "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records/${existing_id}")
    else
        # Create new record
        echo "Record does not exist, creating new record..."
        
        requestDate=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')
        signature=$(echo -n "${requestDate}" | openssl sha1 -hmac "${DNS_API_SECRET}" | cut -d' ' -f2)
        
        response=$(curl -s -X POST \
            -H "x-dnsme-apiKey: ${DNS_API_KEY}" \
            -H "x-dnsme-requestDate: ${requestDate}" \
            -H "x-dnsme-hmac: ${signature}" \
            -H "Content-Type: application/json" \
            -d "${json_payload}" \
            "https://api.dnsmadeeasy.com/V2.0/dns/managed/${domain_id}/records/")
    fi
    
    # Check if successful
    if [[ "$response" =~ "error" ]]; then
        echo -e "${RED}Failed to create/update record${RESET}"
        echo "Response: $response"
        return 1
    else
        echo -e "${GREEN}Successfully created/updated record!${RESET}"
        return 0
    fi
}

# Main execution
echo -e "Starting DNS record creation process..."

# Test API connection first
if ! test_api_connection; then
    echo -e "${RED}API connection test failed. Cannot continue.${RESET}"
    exit 1
fi

# Get domain ID
domain_id=$(get_domain_id)
if [ -z "$domain_id" ]; then
    echo -e "${RED}Failed to get domain ID. Cannot continue.${RESET}"
    exit 1
fi

# Create DNS records

# Create A records (IPv4)
create_dns_record "lg" "A" "${ANYCAST_IPV4}" 300 "${domain_id}"

# Create AAAA records (IPv6)
create_dns_record "lg" "AAAA" "${ANYCAST_IPV6}" 300 "${domain_id}"

echo -e "\n${BOLD}DNS record creation completed.${RESET}"
echo -e "${YELLOW}Note: DNS propagation may take up to 24 hours.${RESET}"
echo -e "\nRecords updated:"
echo -e "- lg.${DOMAIN} -> ${ANYCAST_IPV4} (A)"
echo -e "- lg.${DOMAIN} -> ${ANYCAST_IPV6} (AAAA)"
