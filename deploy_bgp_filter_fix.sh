#!/bin/bash

SSH_KEY="/home/normtodd/.ssh/id_ed25519_nt_infinitum-nihil_com"

# All server IPs
SERVERS=(
    "66.42.113.101"   # ORD  
    "149.28.108.180"  # MIA
    "66.135.18.138"   # EWR
)

echo "Deploying BGP filter fix to all nodes..."

for server in "${SERVERS[@]}"; do
    echo "Fixing $server..."
    
    # Create BGP filters
    ssh -i $SSH_KEY -o ConnectTimeout=5 root@$server "cat > /etc/bird/bgp_filters.conf << 'EOF'
# BGP Import/Export Filters - BLOCK ALL DEFAULT ROUTES

filter ibgp_import {
  # REJECT any default routes first  
  if net = 0.0.0.0/0 then reject;
  if net = ::/0 then reject;
  
  # Accept our IPv4 prefix
  if net = 192.30.120.0/23 then accept;
  # Accept our IPv6 prefix  
  if net = 2620:71:4000::/48 then accept;
  
  # Reject everything else
  reject;
}

filter ibgp_export {
  # NEVER export default routes
  if net = 0.0.0.0/0 then reject;
  if net = ::/0 then reject;
  
  # Export our IPv4 prefix
  if net = 192.30.120.0/23 then accept;
  # Export our IPv6 prefix
  if net = 2620:71:4000::/48 then accept;
  
  # Reject everything else
  reject;
}
EOF"

    # Backup configs
    ssh -i $SSH_KEY -o ConnectTimeout=5 root@$server "cp /etc/bird/bird.conf /etc/bird/bird.conf.backup 2>/dev/null || true"
    
    # Include filters in bird.conf if not already included
    ssh -i $SSH_KEY -o ConnectTimeout=5 root@$server "grep -q 'bgp_filters.conf' /etc/bird/bird.conf || sed -i '1i include \"/etc/bird/bgp_filters.conf\";' /etc/bird/bird.conf"
    
    # Fix kernel protocol exports  
    ssh -i $SSH_KEY -o ConnectTimeout=5 root@$server "sed -i 's/export all;/export where source = RTS_BGP \&\& net != 0.0.0.0\/0 \&\& net != ::\/0;/g' /etc/bird/bird.conf"
    
    # Apply filters to iBGP if not already applied
    ssh -i $SSH_KEY -o ConnectTimeout=5 root@$server "sed -i 's/import all;/import filter ibgp_import;/g' /etc/bird/ibgp.conf 2>/dev/null || true"
    ssh -i $SSH_KEY -o ConnectTimeout=5 root@$server "sed -i 's/export all;/export filter ibgp_export;/g' /etc/bird/ibgp.conf 2>/dev/null || true"
    
    # Restart BIRD
    ssh -i $SSH_KEY -o ConnectTimeout=5 root@$server "systemctl restart bird"
    
    echo "$server fixed"
done

echo "BGP filter fix deployed to all nodes"