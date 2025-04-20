#!/bin/bash
# Script to update hostnames for all BGP servers

# Source environment variables
source "$(dirname "$0")/.env"

# Server information
PRIMARY_IP=$(cat "$HOME/birdbgp/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null)
SECONDARY_IP=$(cat "$HOME/birdbgp/ewr-ipv4-bgp-primary-1c1g_ipv4.txt" 2>/dev/null)
TERTIARY_IP=$(cat "$HOME/birdbgp/mia-ipv4-bgp-secondary-1c1g_ipv4.txt" 2>/dev/null)
QUATERNARY_IP=$(cat "$HOME/birdbgp/ord-ipv4-bgp-tertiary-1c1g_ipv4.txt" 2>/dev/null)

# Text formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"

echo -e "${BOLD}Updating Hostnames for BGP Servers${RESET}"
echo "==============================================="
echo -e "${GREEN}Primary (LAX):${RESET} $PRIMARY_IP"
echo -e "${GREEN}Secondary (EWR):${RESET} $SECONDARY_IP"
echo -e "${GREEN}Tertiary (MIA):${RESET} $TERTIARY_IP"
echo -e "${GREEN}Quaternary (ORD):${RESET} $QUATERNARY_IP"
echo "==============================================="

# Function to update hostname
update_hostname() {
  local server_ip=$1
  local region=$2
  local role=$3
  
  echo -e "${BOLD}Updating hostname for $role server in $region ($server_ip)...${RESET}"
  
  # Create the new hostname
  HOSTNAME="${region}-${role}-bgp"
  FQDN="${HOSTNAME}.${DOMAIN}"
  
  # Generate and execute the hostname update script
  cat > /tmp/update_hostname.sh << EOF
#!/bin/bash
set -e

# Set the new hostname
echo "$HOSTNAME" > /etc/hostname
hostname "$HOSTNAME"

# Update /etc/hosts file
if grep -q "127.0.1.1" /etc/hosts; then
  # Replace existing entry
  sed -i "s/127.0.1.1.*/127.0.1.1\t$FQDN\t$HOSTNAME/" /etc/hosts
else
  # Add new entry
  echo "127.0.1.1\t$FQDN\t$HOSTNAME" >> /etc/hosts
fi

# Update cloud-init to prevent hostname from being reset
if [ -f /etc/cloud/cloud.cfg ]; then
  if grep -q "preserve_hostname" /etc/cloud/cloud.cfg; then
    sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
  else
    echo "preserve_hostname: true" >> /etc/cloud/cloud.cfg
  fi
fi

# Update prompt to show new hostname
cat > /etc/profile.d/hostname-prompt.sh << 'PROMPT'
PS1='\${debian_chroot:+(\$debian_chroot)}\[\033[01;32m\]\u@$HOSTNAME\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\\$ '
PROMPT
chmod +x /etc/profile.d/hostname-prompt.sh

echo "Hostname updated to $FQDN"
echo "Changes will be fully applied after reboot"
EOF

  # Copy the script to the server
  echo "Copying script to $server_ip..."
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/update_hostname.sh "root@$server_ip:/tmp/update_hostname.sh"
  
  # Execute the script
  echo "Executing script on $server_ip..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "root@$server_ip" "chmod +x /tmp/update_hostname.sh && /tmp/update_hostname.sh"
  
  echo -e "${GREEN}✓ Hostname updated on $role server in $region${RESET}"
  echo ""
}

# Update hostnames for all servers
update_hostname "$PRIMARY_IP" "${BGP_REGION_PRIMARY}" "primary"
update_hostname "$SECONDARY_IP" "${BGP_REGION_SECONDARY}" "secondary" 
update_hostname "$TERTIARY_IP" "${BGP_REGION_TERTIARY}" "tertiary"
update_hostname "$QUATERNARY_IP" "${BGP_REGION_QUATERNARY}" "quaternary"

echo -e "${GREEN}All hostnames updated!${RESET}"
echo ""
echo "The new hostnames are:"
echo "  - Primary: ${BGP_REGION_PRIMARY}-primary-bgp.${DOMAIN}"
echo "  - Secondary: ${BGP_REGION_SECONDARY}-secondary-bgp.${DOMAIN}"
echo "  - Tertiary: ${BGP_REGION_TERTIARY}-tertiary-bgp.${DOMAIN}"
echo "  - Quaternary: ${BGP_REGION_QUATERNARY}-quaternary-bgp.${DOMAIN}"
echo ""
echo "To apply all changes, reboot each server:"
echo "  ssh root@$PRIMARY_IP reboot"
echo "  ssh root@$SECONDARY_IP reboot"
echo "  ssh root@$TERTIARY_IP reboot"
echo "  ssh root@$QUATERNARY_IP reboot"