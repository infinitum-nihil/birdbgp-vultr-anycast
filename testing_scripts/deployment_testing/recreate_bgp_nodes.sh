#!/bin/bash

# Recreate BGP mesh nodes with clean cloud-init configurations

SSH_KEY="/home/normtodd/.ssh/id_ed25519_nt_infinitum-nihil_com" 
# Load API key from environment or .env file
if [ -f ".env" ]; then
    source .env
fi

if [ -z "$VULTR_API_KEY" ]; then
    echo "ERROR: VULTR_API_KEY not set. Set environment variable or create .env file"
    exit 1
fi

# Node configurations
declare -A NODES=(
    ["ord"]="66.42.113.101"
    ["mia"]="149.28.108.180" 
    ["ewr"]="66.135.18.138"
)

declare -A INSTANCE_IDS=(
    ["ord"]="9c446839-0d8c-4a42-8f90-da79dd8c787f"
    ["mia"]="335d2db9-8b08-4564-b82d-9daf51f1d2e8"
    ["ewr"]="1a0df53b-aab4-4bde-a7ea-1c6387e7b54b"
)

declare -A LABELS=(
    ["ord"]="ord-bgp-secondary-1c1g"
    ["mia"]="mia-bgp-tertiary-1c1g"
    ["ewr"]="ewr-bgp-quaternary-1c1g"
)

declare -A ROLES=(
    ["ord"]="secondary"
    ["mia"]="tertiary"
    ["ewr"]="quaternary"
)

# Get current instance details for recreation
get_instance_config() {
    local instance_id=$1
    curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
         "https://api.vultr.com/v2/instances/$instance_id" | \
         jq '{
           region: .instance.region,
           plan: .instance.plan, 
           os_id: .instance.os_id,
           firewall_group_id: .instance.firewall_group_id
         }'
}

# Encode cloud-init as base64
CLOUD_INIT_B64=$(base64 -w 0 /home/normtodd/birdbgp/cloud-init-bgp-node.yaml)

echo "=== BGP Mesh Node Recreation ==="
echo "This will destroy and recreate ORD, MIA, and EWR with clean configurations"
echo "LAX will remain unchanged as the route reflector"
echo

# Get SSH key ID
SSH_KEY_ID=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/ssh-keys" | \
    jq -r '.ssh_keys[] | select(.name | contains("nt@infinitum-nihil.com")) | .id')

if [ -z "$SSH_KEY_ID" ]; then
    echo "ERROR: Could not find SSH key for nt@infinitum-nihil.com"
    exit 1
fi

echo "Found SSH key ID: $SSH_KEY_ID"
echo

for node in ord mia ewr; do
    echo "=== Processing $node (${NODES[$node]}) ==="
    
    # Get current instance configuration
    echo "Getting current instance configuration..."
    instance_config=$(get_instance_config ${INSTANCE_IDS[$node]})
    
    if [ -z "$instance_config" ]; then
        echo "ERROR: Could not get configuration for $node"
        continue
    fi
    
    region=$(echo "$instance_config" | jq -r '.region')
    plan=$(echo "$instance_config" | jq -r '.plan') 
    os_id=$(echo "$instance_config" | jq -r '.os_id')
    firewall_group_id=$(echo "$instance_config" | jq -r '.firewall_group_id')
    
    echo "Configuration: region=$region, plan=$plan, os_id=$os_id, firewall=$firewall_group_id"
    
    # Destroy the instance
    echo "Destroying instance ${INSTANCE_IDS[$node]}..."
    curl -s -X DELETE \
         -H "Authorization: Bearer $VULTR_API_KEY" \
         "https://api.vultr.com/v2/instances/${INSTANCE_IDS[$node]}" > /dev/null
    
    echo "Waiting for instance to be destroyed..."
    sleep 10
    
    # Create new instance with cloud-init
    echo "Creating new instance with cloud-init configuration..."
    
    create_response=$(curl -s -X POST \
        -H "Authorization: Bearer $VULTR_API_KEY" \
        -H "Content-Type: application/json" \
        "https://api.vultr.com/v2/instances" \
        -d "{
            \"region\": \"$region\",
            \"plan\": \"$plan\",
            \"os_id\": $os_id,
            \"label\": \"${LABELS[$node]}\",
            \"sshkey_id\": [\"$SSH_KEY_ID\"],
            \"firewall_group_id\": \"$firewall_group_id\",
            \"user_data\": \"$CLOUD_INIT_B64\",
            \"hostname\": \"$node-${ROLES[$node]}-bgp\",
            \"tag\": \"bgp-mesh\"
        }")
    
    new_instance_id=$(echo "$create_response" | jq -r '.instance.id')
    
    if [ "$new_instance_id" = "null" ]; then
        echo "ERROR: Failed to create instance for $node"
        echo "Response: $create_response"
        continue
    fi
    
    echo "New instance created: $new_instance_id"
    echo "Waiting for instance to boot and cloud-init to complete..."
    
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
    
    echo "$node recreation complete!"
    echo
done

echo "=== All nodes recreated ==="
echo "Waiting additional time for cloud-init to complete setup..."
sleep 60

echo "Testing connectivity..."
for node in ord mia ewr; do
    echo "Testing $node (${NODES[$node]})..."
    ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        root@${NODES[$node]} "echo '$node is accessible'" || \
        echo "$node not yet accessible"
done

echo
echo "Node recreation complete! Check cloud-init logs with:"
echo "ssh root@IP 'tail -f /var/log/cloud-init-output.log'"