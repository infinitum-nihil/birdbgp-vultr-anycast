#!/bin/bash
# Restart VMs after floating IP attachment

# Source .env file to get API credentials
source "$(dirname "$0")/.env"

echo "Starting VM restart process after floating IP attachment..."
echo "This is required for Vultr to properly activate the floating IPs."

# Get our instance IDs 
echo "Getting instance details..."
INSTANCES=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")

# Extract instance information
PRIMARY_ID=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-primary[^}]*}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
SECONDARY_ID=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-secondary[^}]*}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
TERTIARY_ID=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-tertiary[^}]*}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
IPV6_ID=$(echo "$INSTANCES" | grep -o "{[^}]*ipv6-bgp[^}]*}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)

# Extract the IP addresses for display
PRIMARY_IP=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-primary[^}]*}" | grep -o '"main_ip":"[^"]*' | cut -d'"' -f4)
SECONDARY_IP=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-secondary[^}]*}" | grep -o '"main_ip":"[^"]*' | cut -d'"' -f4)
TERTIARY_IP=$(echo "$INSTANCES" | grep -o "{[^}]*ipv4-bgp-tertiary[^}]*}" | grep -o '"main_ip":"[^"]*' | cut -d'"' -f4)
IPV6_MAIN_IP=$(echo "$INSTANCES" | grep -o "{[^}]*ipv6-bgp[^}]*}" | grep -o '"main_ip":"[^"]*' | cut -d'"' -f4)

# Function to restart a VM and wait for it to come back online
restart_vm() {
    local vm_id=$1
    local vm_ip=$2
    local vm_label=$3
    
    echo "Restarting $vm_label VM ($vm_ip)..."
    
    # Send restart command to Vultr API
    local restart_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances/$vm_id/reboot" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    echo "Restart command sent. Waiting for VM to come back online..."
    
    # Wait for VM to go offline first 
    local offline=false
    local max_wait=60
    local count=0
    
    while [ "$offline" = false ] && [ $count -lt $max_wait ]; do
        if ping -c 1 -W 1 $vm_ip > /dev/null 2>&1; then
            echo "VM $vm_label still online, waiting... ($count/$max_wait)"
            count=$((count+1))
            sleep 5
        else
            echo "VM $vm_label is now offline."
            offline=true
        fi
    done
    
    # Now wait for it to come back online
    local online=false
    local max_wait=120
    local count=0
    
    while [ "$online" = false ] && [ $count -lt $max_wait ]; do
        if ping -c 1 -W 1 $vm_ip > /dev/null 2>&1; then
            echo "VM $vm_label is back online!"
            online=true
        else
            echo "Waiting for VM $vm_label to come back online... ($count/$max_wait)"
            count=$((count+1))
            sleep 5
        fi
    done
    
    if [ "$online" = true ]; then
        echo "✅ $vm_label VM ($vm_ip) successfully restarted."
        return 0
    else
        echo "❌ Timeout waiting for $vm_label VM ($vm_ip) to come back online."
        return 1
    fi
}

echo "Found instances:"
echo "Primary IPv4 (EWR):   ID=$PRIMARY_ID, IP=$PRIMARY_IP"
echo "Secondary IPv4 (MIA): ID=$SECONDARY_ID, IP=$SECONDARY_IP"
echo "Tertiary IPv4 (ORD):  ID=$TERTIARY_ID, IP=$TERTIARY_IP"
echo "IPv6 (LAX):           ID=$IPV6_ID, IP=$IPV6_MAIN_IP"
echo

# Ask for confirmation
read -p "Do you want to restart all these VMs to activate floating IPs? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Restart cancelled."
    exit 0
fi

# Restart primary VM
restart_vm "$PRIMARY_ID" "$PRIMARY_IP" "Primary (EWR)" || echo "Warning: Primary VM restart may not be complete"

# Restart secondary VM
restart_vm "$SECONDARY_ID" "$SECONDARY_IP" "Secondary (MIA)" || echo "Warning: Secondary VM restart may not be complete"

# Restart tertiary VM
restart_vm "$TERTIARY_ID" "$TERTIARY_IP" "Tertiary (ORD)" || echo "Warning: Tertiary VM restart may not be complete"

# Restart IPv6 VM if it exists
if [ -n "$IPV6_ID" ]; then
    restart_vm "$IPV6_ID" "$IPV6_MAIN_IP" "IPv6 (LAX)" || echo "Warning: IPv6 VM restart may not be complete"
fi

echo
echo "All VMs have been restarted. Floating IPs should now be properly activated."
echo "You can verify this by checking the Vultr control panel or by connecting to each VM."
echo "After all VMs are back online, run the following command to check BGP status:"
echo "  ./deploy.sh monitor"