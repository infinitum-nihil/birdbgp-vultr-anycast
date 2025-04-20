#!/bin/bash

CONFIG_FILE="bgp_cloud_config.json"
TEMP_FILE=$(mktemp)

# Function to add a new provider
add_provider() {
    local provider=$1
    local provider_type=$2
    local api_version=$3

    jq --arg provider "$provider" \
       --arg type "$provider_type" \
       --arg version "$api_version" \
       '.cloud_providers[$provider] = {
         "servers": {},
         "authentication": {
           "last_rotated": "'$(date +%Y-%m-%d)'"
         },
         "metadata": {
           "provider_type": $type,
           "api_version": $version,
           "region_mapping": {}
         }
       }' "$CONFIG_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$CONFIG_FILE"
}

# Function to add a server to a provider
add_server() {
    local provider=$1
    local region=$2
    local location=$3
    local ipv4=$4
    local ipv6=$5
    local role=$6

    local update=$(jq --arg provider "$provider" \
                      --arg region "$region" \
                      --arg location "$location" \
                      --arg ipv4 "$ipv4" \
                      --arg ipv6 "$ipv6" \
                      --arg role "$role" \
                      --arg date "$(date +%Y-%m-%d)" \
                      '.cloud_providers[$provider].servers[$region][$location] = {
                        "ipv4": {
                          "address": $ipv4,
                          "role": $role,
                          "last_updated": $date
                        }
                      } + (if $ipv6 != "" then {
                        "ipv6": {
                          "address": $ipv6,
                          "role": $role,
                          "last_updated": $date
                        }
                      } else {} end)' "$CONFIG_FILE")

    echo "$update" > "$TEMP_FILE" && mv "$TEMP_FILE" "$CONFIG_FILE"
}

# Function to update authentication
update_auth() {
    local provider=$1
    local key_type=$2
    local key_value=$3

    jq --arg provider "$provider" \
       --arg type "$key_type" \
       --arg value "$key_value" \
       --arg date "$(date +%Y-%m-%d)" \
       '.cloud_providers[$provider].authentication[$type] = $value |
        .cloud_providers[$provider].authentication.last_rotated = $date' \
       "$CONFIG_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$CONFIG_FILE"
}

# Function to list providers
list_providers() {
    jq -r '.cloud_providers | keys[]' "$CONFIG_FILE"
}

# Function to show provider details
show_provider() {
    local provider=$1
    jq ".cloud_providers.$provider" "$CONFIG_FILE"
}

# Main script
case "$1" in
    "add")
        if [ "$#" -lt 4 ]; then
            echo "Usage: $0 add <provider> <type> <api_version>"
            exit 1
        fi
        add_provider "$2" "$3" "$4"
        ;;
    "add-server")
        if [ "$#" -lt 7 ]; then
            echo "Usage: $0 add-server <provider> <region> <location> <ipv4> <ipv6> <role>"
            exit 1
        fi
        add_server "$2" "$3" "$4" "$5" "$6" "$7"
        ;;
    "update-auth")
        if [ "$#" -lt 4 ]; then
            echo "Usage: $0 update-auth <provider> <key_type> <key_value>"
            exit 1
        fi
        update_auth "$2" "$3" "$4"
        ;;
    "list")
        list_providers
        ;;
    "show")
        if [ "$#" -lt 2 ]; then
            echo "Usage: $0 show <provider>"
            exit 1
        fi
        show_provider "$2"
        ;;
    *)
        echo "Usage: $0 {add|add-server|update-auth|list|show}"
        exit 1
        ;;
esac

# Validate the configuration after changes
./validate_config.sh 