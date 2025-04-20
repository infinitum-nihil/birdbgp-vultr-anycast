#!/bin/bash
# Script to create necessary DNS records manually 
# (when API authentication fails)

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Define variables
DOMAIN="infinitum-nihil.com"
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"
LG_HOSTNAME="lg"

clear
echo -e "${BLUE}${BOLD}========================================================${NC}"
echo -e "${BLUE}${BOLD}========================================================${NC}"
echo ""
echo -e "${YELLOW}and Traefik dashboard to make them accessible on the internet.${NC}"
echo ""
echo -e "${BOLD}Domain:${NC} $DOMAIN"
echo -e "${BOLD}Anycast IPv4:${NC} $ANYCAST_IPV4"
echo -e "${BOLD}Anycast IPv6:${NC} $ANYCAST_IPV6"
echo ""
echo -e "${BLUE}${BOLD}These are the DNS records you need to create:${NC}"
echo ""
echo -e "1. ${GREEN}A Record${NC}"
echo "   Hostname: $LG_HOSTNAME"
echo "   Value: $ANYCAST_IPV4"
echo "   TTL: 300 seconds"
echo "   Result: $LG_HOSTNAME.$DOMAIN -> $ANYCAST_IPV4"
echo ""
echo -e "2. ${GREEN}AAAA Record${NC}"
echo "   Hostname: $LG_HOSTNAME"
echo "   Value: $ANYCAST_IPV6"
echo "   TTL: 300 seconds"
echo "   Result: $LG_HOSTNAME.$DOMAIN -> $ANYCAST_IPV6"
echo ""
echo -e "3. ${GREEN}A Record${NC}"
echo "   Hostname: $TRAEFIK_HOSTNAME"
echo "   Value: $ANYCAST_IPV4"
echo "   TTL: 300 seconds"
echo "   Result: $TRAEFIK_HOSTNAME.$DOMAIN -> $ANYCAST_IPV4"
echo ""
echo -e "4. ${GREEN}AAAA Record${NC}"
echo "   Hostname: $TRAEFIK_HOSTNAME"
echo "   Value: $ANYCAST_IPV6"
echo "   TTL: 300 seconds"
echo "   Result: $TRAEFIK_HOSTNAME.$DOMAIN -> $ANYCAST_IPV6"
echo ""
echo -e "${BLUE}${BOLD}Steps to create these records:${NC}"
echo ""
echo -e "1. Log in to your DNS provider (DNSMadeEasy)"
echo -e "2. Navigate to the DNS management section"
echo -e "3. Select the domain: ${BOLD}$DOMAIN${NC}"
echo -e "4. Add each record with the details above"
echo -e "5. Save your changes"
echo ""
echo -e "${YELLOW}${BOLD}After DNS propagation (may take up to 24 hours):${NC}"
echo ""
echo -e "Your Traefik dashboard will be available at: ${BOLD}https://$TRAEFIK_HOSTNAME.$DOMAIN${NC}"
echo ""
echo -e "${BLUE}${BOLD}Checking DNS propagation:${NC}"
echo ""
echo -e "Run these commands to check if DNS records have propagated:"
echo -e "  ${BOLD}host $LG_HOSTNAME.$DOMAIN${NC}"
echo -e "  ${BOLD}host $TRAEFIK_HOSTNAME.$DOMAIN${NC}"
echo ""
echo -e "${BLUE}${BOLD}========================================================${NC}"
echo -e "${YELLOW}Once DNS records propagate, everything should work.${NC}"
echo -e "${BLUE}${BOLD}========================================================${NC}"

# Save this info to a file for future reference
echo "Saving these instructions to a file for future reference..."
cat > /home/normtodd/birdbgp/dns_instructions.txt << EOF
DNS RECORD CREATION INSTRUCTIONS

Domain: $DOMAIN
Anycast IPv4: $ANYCAST_IPV4
Anycast IPv6: $ANYCAST_IPV6

DNS RECORDS TO CREATE:
1. A Record
   Hostname: $LG_HOSTNAME
   Value: $ANYCAST_IPV4
   TTL: 300 seconds
   Result: $LG_HOSTNAME.$DOMAIN -> $ANYCAST_IPV4

2. AAAA Record
   Hostname: $LG_HOSTNAME
   Value: $ANYCAST_IPV6
   TTL: 300 seconds
   Result: $LG_HOSTNAME.$DOMAIN -> $ANYCAST_IPV6

3. A Record
   Hostname: $TRAEFIK_HOSTNAME
   Value: $ANYCAST_IPV4
   TTL: 300 seconds
   Result: $TRAEFIK_HOSTNAME.$DOMAIN -> $ANYCAST_IPV4

4. AAAA Record
   Hostname: $TRAEFIK_HOSTNAME
   Value: $ANYCAST_IPV6
   TTL: 300 seconds
   Result: $TRAEFIK_HOSTNAME.$DOMAIN -> $ANYCAST_IPV6

After DNS propagation:
- Hyperglass: https://$LG_HOSTNAME.$DOMAIN
- Traefik: https://$TRAEFIK_HOSTNAME.$DOMAIN

Check DNS propagation:
  host $LG_HOSTNAME.$DOMAIN
  host $TRAEFIK_HOSTNAME.$DOMAIN
EOF

echo -e "Instructions saved to: ${BOLD}/home/normtodd/birdbgp/dns_instructions.txt${NC}"

# Attempt a DNS lookup to check if records already exist
echo -e "\n${BLUE}${BOLD}Checking if DNS records already exist:${NC}"
host $LG_HOSTNAME.$DOMAIN || echo -e "${YELLOW}Record not found - needs to be created${NC}"