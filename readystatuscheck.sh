#!/bin/bash

# BGP Node Readiness Status Checker
# Monitors Vultr instances until they reach ready status (active/running/ok)

cd /home/normtodd/birdbgp && source .env

echo "BGP Node Readiness Monitor - $(date)"
echo "Monitoring instances until server_status = 'ok'"
echo "============================================"

declare -A INSTANCE_IDS=(
    ["ord"]="d62b22c2-9e6f-4240-aaf9-85a612d79cd2"
    ["mia"]="e31b287b-e30e-463f-b971-ec98e9e3c180"
    ["ewr"]="13163a53-9039-4a66-a57b-c77c0206f54f"
)

declare -A READY_STATUS=(["ord"]="false" ["mia"]="false" ["ewr"]="false")
declare -A LAST_STATUS=(["ord"]="" ["mia"]="" ["ewr"]="")

while true; do
    all_ready=true
    
    for node in ord mia ewr; do
        if [ "${READY_STATUS[$node]}" = "false" ]; then
            response=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" "https://api.vultr.com/v2/instances/${INSTANCE_IDS[$node]}")
            
            status=$(echo "$response" | jq -r '.instance.status')
            power_status=$(echo "$response" | jq -r '.instance.power_status')
            server_status=$(echo "$response" | jq -r '.instance.server_status')
            main_ip=$(echo "$response" | jq -r '.instance.main_ip')
            
            current_status="$status,$power_status,$server_status"
            
            # Only print if status changed
            if [ "$current_status" != "${LAST_STATUS[$node]}" ]; then
                echo "$(date '+%H:%M:%S') $node: $status/$power_status/$server_status (IP: $main_ip)"
                LAST_STATUS[$node]="$current_status"
            fi
            
            if [ "$status" = "active" ] && [ "$power_status" = "running" ] && [ "$server_status" = "ok" ]; then
                echo "✅ $(date '+%H:%M:%S') $node is ready!"
                READY_STATUS[$node]="true"
                echo "$main_ip" > ${node}_final_ip.txt
            else
                all_ready=false
            fi
        fi
    done
    
    if [ "$all_ready" = "true" ]; then
        echo "============================================"
        echo "✅ $(date '+%H:%M:%S') All nodes ready!"
        echo "Cloud-init bootstrap can now be monitored."
        echo "Use: ssh root@\$(cat ord_final_ip.txt) 'tail -f /var/log/bgp-node-bootstrap.log'"
        break
    fi
    
    sleep 20
done