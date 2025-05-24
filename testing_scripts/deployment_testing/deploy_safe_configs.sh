#!/bin/bash
# Safe configuration deployment script
# Backs up existing configs before deployment

set -e  # Exit on any error

NODES=("lax" "ord" "mia" "ewr")
IPS=("149.248.2.74" "66.42.113.101" "149.28.108.180" "66.135.18.138")
CONFIG_DIR="/home/normtodd/birdbgp/generated_configs"

echo "=== Safe BGP Configuration Deployment ==="
echo "This script will:"
echo "1. Backup existing configurations on all nodes"
echo "2. Deploy new configurations via SCP"
echo "3. Restart services safely"
echo

# Function to backup configs on a node
backup_node_configs() {
    local node=$1
    local ip=$2
    
    echo "Backing up configs on $node ($ip)..."
    
    ssh root@$ip "
        mkdir -p /etc/bird/backup/$(date +%Y%m%d_%H%M%S)
        BACKUP_DIR=/etc/bird/backup/$(date +%Y%m%d_%H%M%S)
        
        # Backup BIRD configs
        cp /etc/bird.conf \$BACKUP_DIR/ 2>/dev/null || true
        cp /etc/bird/*.conf \$BACKUP_DIR/ 2>/dev/null || true
        
        # Backup WireGuard configs  
        cp /etc/wireguard/*.conf \$BACKUP_DIR/ 2>/dev/null || true
        
        echo 'Backup completed in:' \$BACKUP_DIR
    " || echo "Warning: Backup failed for $node"
}

# Function to deploy configs to a node
deploy_node_configs() {
    local node=$1
    local ip=$2
    
    echo "Deploying configs to $node ($ip)..."
    
    if [ ! -d "$CONFIG_DIR/$node" ]; then
        echo "Error: No generated configs found for $node"
        return 1
    fi
    
    # Deploy BIRD configs
    scp $CONFIG_DIR/$node/*.conf root@$ip:/etc/bird/
    
    # Deploy WireGuard configs if they exist
    if [ -f "$CONFIG_DIR/$node/${node}-wg-v4.conf" ]; then
        scp $CONFIG_DIR/$node/${node}-wg-v4.conf root@$ip:/etc/wireguard/
    fi
    
    echo "Configs deployed to $node"
}

# Function to restart services on a node
restart_node_services() {
    local node=$1
    local ip=$2
    
    echo "Restarting services on $node ($ip)..."
    
    ssh root@$ip "
        # Stop services first
        systemctl stop bird 2>/dev/null || true
        systemctl stop wg-quick@wg0 2>/dev/null || true
        systemctl stop wg-quick@${node}-wg-v4 2>/dev/null || true
        
        # Start WireGuard first
        systemctl start wg-quick@${node}-wg-v4 2>/dev/null || echo 'WireGuard start skipped'
        sleep 2
        
        # Start BIRD
        systemctl start bird
        sleep 5
        
        # Verify
        systemctl status bird --no-pager -l | head -10
    " || echo "Warning: Service restart issues on $node"
}

# Main deployment process
echo "Starting safe deployment process..."

# Generate all configs first
echo "Generating configurations..."
for node in "${NODES[@]}"; do
    python3 /home/normtodd/birdbgp/generate_configs.py /home/normtodd/birdbgp/bgp_config.json $node
done

# Backup all nodes
echo -e "\n=== Phase 1: Backup existing configurations ==="
for i in "${!NODES[@]}"; do
    backup_node_configs "${NODES[$i]}" "${IPS[$i]}"
done

# Deploy to all nodes  
echo -e "\n=== Phase 2: Deploy new configurations ==="
for i in "${!NODES[@]}"; do
    deploy_node_configs "${NODES[$i]}" "${IPS[$i]}"
done

# Restart services (start with LAX last since it's route reflector)
echo -e "\n=== Phase 3: Restart services ==="
for i in 1 2 3 0; do  # ORD, MIA, EWR, then LAX
    restart_node_services "${NODES[$i]}" "${IPS[$i]}"
    sleep 10  # Allow time for BGP convergence
done

echo -e "\n=== Deployment Complete ==="
echo "Verify BGP status with: ssh root@149.248.2.74 \"birdc 'show protocols'\""