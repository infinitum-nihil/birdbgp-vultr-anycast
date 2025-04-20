#!/bin/bash

# Function to get IP from JSON config
get_ip_from_json() {
    local provider=$1
    local region=$2
    local location=$3
    local ip_type=$4
    jq -r ".cloud_providers.$provider.servers.$region.$location.$ip_type.address" bgp_cloud_config.json
}

# Function to update a script
update_script() {
    local script=$1
    local temp_file=$(mktemp)

    # Create a new version of the script with updated IP retrieval
    sed -e "s/PRIMARY_IP=\$(cat .*lax-ipv6-bgp-1c1g_ipv4.txt.*)/PRIMARY_IP=\$(get_ip_from_json vultr us-west lax ipv4)/g" \
        -e "s/SECONDARY_IP=\$(cat .*ewr-ipv4-bgp-primary-1c1g_ipv4.txt.*)/SECONDARY_IP=\$(get_ip_from_json vultr us-east ewr ipv4)/g" \
        -e "s/TERTIARY_IP=\$(cat .*mia-ipv4-bgp-secondary-1c1g_ipv4.txt.*)/TERTIARY_IP=\$(get_ip_from_json vultr us-east mia ipv4)/g" \
        -e "s/QUATERNARY_IP=\$(cat .*ord-ipv4-bgp-tertiary-1c1g_ipv4.txt.*)/QUATERNARY_IP=\$(get_ip_from_json vultr us-central ord ipv4)/g" \
        -e "s/LAX_IP=\$(cat .*lax-ipv6-bgp-1c1g_ipv4.txt.*)/LAX_IP=\$(get_ip_from_json vultr us-west lax ipv4)/g" \
        -e "s/EWR_IP=\$(cat .*ewr-ipv4-bgp-primary-1c1g_ipv4.txt.*)/EWR_IP=\$(get_ip_from_json vultr us-east ewr ipv4)/g" \
        -e "s/MIA_IP=\$(cat .*mia-ipv4-bgp-secondary-1c1g_ipv4.txt.*)/MIA_IP=\$(get_ip_from_json vultr us-east mia ipv4)/g" \
        -e "s/ORD_IP=\$(cat .*ord-ipv4-bgp-tertiary-1c1g_ipv4.txt.*)/ORD_IP=\$(get_ip_from_json vultr us-central ord ipv4)/g" \
        "$script" > "$temp_file"

    # Add the get_ip_from_json function if it's not already present
    if ! grep -q "get_ip_from_json" "$temp_file"; then
        cat > "$temp_file.new" << 'EOF'
#!/bin/bash

# Function to get IP from JSON config
get_ip_from_json() {
    local provider=$1
    local region=$2
    local location=$3
    local ip_type=$4
    jq -r ".cloud_providers.$provider.servers.$region.$location.$ip_type.address" "$(dirname "$0")/config_files/bgp_cloud_config.json"
}

EOF
        cat "$temp_file" >> "$temp_file.new"
        mv "$temp_file.new" "$temp_file"
    fi

    # Make the script executable and replace the original
    chmod +x "$temp_file"
    mv "$temp_file" "$script"
}

# List of scripts to update
scripts=(
    "implement_path_prepending.sh"
    "upgrade_bird.sh"
    "setup_bird.sh"
    "add_path_prepending.sh"
    "deployment_scripts/deploy_lax_only.sh"
    "deployment_scripts/deploy_all_servers.sh"
    "deployment_scripts/deploy_temp.sh"
    "vm_management/update_hostnames.sh"
    "fix_deploy_temp.sh"
)

# Update each script
for script in "${scripts[@]}"; do
    if [ -f "$script" ]; then
        echo "Updating $script..."
        update_script "$script"
    else
        echo "Warning: $script not found"
    fi
done

echo "Script updates complete. Please review the changes before committing." 