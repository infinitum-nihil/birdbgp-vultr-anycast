#\!/bin/bash

# Load environment variables
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo "Loaded environment variables from $ENV_FILE"
else
    echo "Error: Environment file not found: $ENV_FILE"
    exit 1
fi

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"

# Get server IPs from the birdbgp directory
LAX_IP=$(cat "$HOME/birdbgp/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
EWR_IP=$(cat "$HOME/birdbgp/ewr-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
MIA_IP=$(cat "$HOME/birdbgp/mia-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
ORD_IP=$(cat "$HOME/birdbgp/ord-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)

echo "======================================="
echo -e "Primary (LAX): ${LAX_IP}"
echo -e "Secondary (EWR): ${EWR_IP}"
echo -e "Tertiary (MIA): ${MIA_IP}"
echo -e "Quaternary (ORD): ${ORD_IP}"
echo "======================================="
echo -e "Assigning Anycast IPs: 192.30.120.10 and 2620:71:4000::c01e:780a"
echo -e "Domain name: ${DOMAIN}"
echo -e "Let's Encrypt email: ${LETSENCRYPT_EMAIL:-ssl@$DOMAIN}"
echo -e "DNS Provider: ${DNS_PROVIDER}"
echo ""

# Function to deploy to a server
deploy_to_server() {
    local server_ip=$1
    local server_role=$2
    local server_region=$3
    
    echo "Deploying to $server_role ($server_region) - $server_ip..."
    
    # Create a temporary .env file for the server with only the needed variables
    cat > /tmp/server_env << EOF_ENV
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-"ssl@$DOMAIN"}
SERVER_ROLE=${server_role}
SERVER_REGION=${server_region}
EOF_ENV
    
    # Copy the files to the server
    scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/server_env "root@$server_ip:/tmp/server_env"
    
    # Execute the script remotely
    echo "Running deployment script on $server_ip..."
    
    echo "Deployment to $server_region completed."
    echo ""
}

# Deploy to LAX (Primary)
if [ -n "$LAX_IP" ]; then
    deploy_to_server "$LAX_IP" "Primary" "LAX"
else
    echo -e "${RED}Error: LAX IP not found${RESET}"
fi

# Deploy to EWR (Secondary)
if [ -n "$EWR_IP" ]; then
    deploy_to_server "$EWR_IP" "Secondary" "EWR"
else
    echo -e "${RED}Error: EWR IP not found${RESET}"
fi

# Deploy to MIA (Tertiary)
if [ -n "$MIA_IP" ]; then
    deploy_to_server "$MIA_IP" "Tertiary" "MIA"
else
    echo -e "${RED}Error: MIA IP not found${RESET}"
fi

# Deploy to ORD (Quaternary)
if [ -n "$ORD_IP" ]; then
    deploy_to_server "$ORD_IP" "Quaternary" "ORD"
else
    echo -e "${RED}Error: ORD IP not found${RESET}"
fi

echo -e "${GREEN}Deployment to all servers completed.${RESET}"
