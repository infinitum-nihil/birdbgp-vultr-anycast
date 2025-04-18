#!/bin/bash

# Update deployment state to simulate completed floating IP stage
# This allows continuing with BIRD configuration without floating IPs

# Set the stage to BIRD_CONFIGS (4) to skip IP creation/attachment
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"stage\": 4,\"timestamp\": \"$TIMESTAMP\",\"message\": \"Manually set to BIRD configuration stage\",\"ipv4_instances\": [],\"ipv6_instance\": null,\"floating_ipv4_ids\": [],\"floating_ipv6_id\": null}" > "$(dirname "$0")/deployment_state.json"

echo "Updated deployment state to BIRD configuration stage."
echo "You can now run './deploy.sh continue' to proceed with BIRD configuration."
echo "NOTE: Floating IPs are not actually created due to quota limits."
echo "You will need to create them manually later when your quota limit is increased."