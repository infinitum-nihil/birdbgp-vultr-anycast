#!/bin/bash

#
# Production BGP Anycast Mesh Deployment Script
#
# This script deploys a production-ready BGP anycast mesh with service discovery
# architecture. It creates self-configuring BGP nodes that automatically discover
# their configuration through a centralized service discovery API.
#
# Features:
# - Ubuntu 24.04 LTS with latest security updates pre-installed
# - Service discovery API for dynamic configuration management
# - Cloud-init bootstrap for fully automated node setup
# - WireGuard mesh network with IPv4/IPv6 tunnels
# - BIRD 2.17.1 with dual-stack BGP and MD5 authentication
# - Anycast IP announcement on 192.30.120.0/23
# - Secure firewall configuration with UFW
#
# Prerequisites:
# - Vultr API key with full access
# - Service discovery API running on LAX node (149.248.2.74:5000)
# - SSH key uploaded to Vultr
# - BGP firewall group configured
#
# Usage: ./deploy_production_mesh.sh
#

# Load API key from environment or .env file
# This ensures secure API key management without hardcoding
if [ -f ".env" ]; then
    source .env
fi

if [ -z "$VULTR_API_KEY" ]; then
    echo "ERROR: VULTR_API_KEY not set. Set environment variable or create .env file"
    echo "Example: export VULTR_API_KEY=your_api_key_here"
    exit 1
fi
# Vultr configuration IDs
# These IDs are specific to this deployment and should be updated for different environments
SSH_KEY_ID="9bd72db9-f745-4b0f-b9b2-55c967f3fae1"              # SSH key for nt@infinitum-nihil.com (legacy)
SSH_KEY_ID_CURRENT="f190effd-73b3-4ac1-8b6a-0d847703e45f"      # SSH key for normtodd@NTubuntu (current)
FIREWALL_GROUP_ID="c07c67b8-7cd2-405a-a559-65578a1edbad"       # BGP Servers firewall group

# STANDARD PROCEDURE: Always include both SSH keys for compatibility and current access
# STANDARD PROCEDURE: Always enable IPv6 (enable_ipv6: true) for dual-stack BGP
# STANDARD PROCEDURE: Nodes self-register with service discovery API (no need to pre-populate IPs)

# Node configuration arrays
# These define the BGP mesh topology and will be replaced during deployment
declare -A NODES=(
    ["ord"]="45.76.19.248"     # Chicago - Secondary BGP node
    ["mia"]="45.77.74.248"     # Miami - Tertiary BGP node
    ["ewr"]="108.61.142.4"     # Newark - Quaternary BGP node
)

# Instance IDs for cleanup/management (updated with current instances)
declare -A INSTANCE_IDS=(
    ["ord"]="30fbb3f6-c9dd-4454-8053-32fb0ec58f0d"
    ["mia"]="5d9ae504-47b1-4c08-b42e-fbb8c5b31dec"
    ["ewr"]="ac4cc7d6-bfcc-47c8-a254-b2479b572c4b"
)

# Node labels for Vultr identification (upgrading to 2c2g for BGP + Docker)
declare -A LABELS=(
    ["ord"]="ord-bgp-secondary-2c2g"     # 2 CPU, 2GB RAM instance
    ["mia"]="mia-bgp-tertiary-2c2g"      # 2 CPU, 2GB RAM instance
    ["ewr"]="ewr-bgp-quaternary-2c2g"    # 2 CPU, 2GB RAM instance
)

# BGP hierarchy roles for route reflection topology
declare -A ROLES=(
    ["ord"]="secondary"    # Connects to LAX route reflector
    ["mia"]="tertiary"     # Connects to LAX route reflector
    ["ewr"]="quaternary"   # Connects to LAX route reflector
)

# Encode cloud-init as base64
echo "Encoding cloud-init configuration..."
CLOUD_INIT_B64=$(base64 -w 0 cloud-init-with-service-discovery.yaml)

echo "=== BGP Anycast Mesh Production Deployment ==="
echo "Deploying service discovery-driven BGP mesh"
echo "Service Discovery API: http://149.248.2.74:5000"
echo

# Get current instance config for each node
get_instance_config() {
    local instance_id=$1
    curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
         "https://api.vultr.com/v2/instances/$instance_id" | \
         jq '{
           region: .instance.region,
           plan: .instance.plan, 
           os_id: .instance.os_id
         }'
}

for node in ord mia ewr; do
    echo "=== Deploying $node (${NODES[$node]}) ==="
    
    # Get current instance configuration
    echo "Getting current instance configuration..."
    instance_config=$(get_instance_config ${INSTANCE_IDS[$node]})
    
    if [ -z "$instance_config" ] || [ "$instance_config" = "null" ]; then
        echo "ERROR: Could not get configuration for $node"
        continue
    fi
    
    region=$(echo "$instance_config" | jq -r '.region')
    plan=$(echo "$instance_config" | jq -r '.plan') 
    os_id=$(echo "$instance_config" | jq -r '.os_id')
    
    echo "Configuration: region=$region, plan=$plan, os_id=$os_id"
    
    # Destroy the current instance
    echo "Destroying current instance ${INSTANCE_IDS[$node]}..."
    curl -s -X DELETE \
         -H "Authorization: Bearer $VULTR_API_KEY" \
         "https://api.vultr.com/v2/instances/${INSTANCE_IDS[$node]}" > /dev/null
    
    echo "Waiting for instance to be destroyed..."
    sleep 15
    
    # Create new instance with service discovery cloud-init
    echo "Creating new instance with service discovery cloud-init..."
    
    create_response=$(curl -s -X POST \
        -H "Authorization: Bearer $VULTR_API_KEY" \
        -H "Content-Type: application/json" \
        "https://api.vultr.com/v2/instances" \
        -d "{
            \"region\": \"$region\",
            \"plan\": \"$plan\",
            \"os_id\": $os_id,
            \"label\": \"${LABELS[$node]}\",
            \"sshkey_id\": [\"$SSH_KEY_ID\", \"f190effd-73b3-4ac1-8b6a-0d847703e45f\"],
            \"firewall_group_id\": \"$FIREWALL_GROUP_ID\",
            \"user_data\": \"$CLOUD_INIT_B64\",
            \"hostname\": \"$node-${ROLES[$node]}-bgp\",
            \"tag\": \"bgp-mesh-service-discovery\",
            \"enable_ipv6\": true
        }")
    
    new_instance_id=$(echo "$create_response" | jq -r '.instance.id')
    new_instance_ip=$(echo "$create_response" | jq -r '.instance.main_ip')
    
    if [ "$new_instance_id" = "null" ]; then
        echo "ERROR: Failed to create instance for $node"
        echo "Response: $create_response"
        continue
    fi
    
    echo "New instance created: $new_instance_id"
    echo "New IP address: $new_instance_ip"
    echo "Waiting for instance to boot and configure..."
    
    # Wait for instance to be active
    for i in {1..60}; do
        status=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
                 "https://api.vultr.com/v2/instances/$new_instance_id" | \
                 jq -r '.instance.status')
        
        if [ "$status" = "active" ]; then
            echo "Instance is active (attempt $i/60)"
            break
        fi
        
        echo "Instance status: $status (waiting...)"
        sleep 10
    done
    
    echo "$node deployment initiated!"
    echo "New Instance ID: $new_instance_id"
    echo "New IP: $new_instance_ip"
    echo
done

echo "=== All nodes deployed ==="
echo "Waiting for cloud-init to complete (this may take 10-15 minutes)..."
echo
echo "Monitor progress with:"
echo "ssh root@NEW_IP 'tail -f /var/log/bgp-node-bootstrap.log'"
echo
echo "Check service discovery API status:"
echo "curl http://149.248.2.74:5000/api/v1/status"