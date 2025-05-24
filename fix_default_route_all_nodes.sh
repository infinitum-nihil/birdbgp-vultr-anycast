#!/bin/bash

SSH_KEY="/home/normtodd/.ssh/id_ed25519_nt_infinitum-nihil_com"

# Servers to fix
SERVERS=(
    "66.42.113.101"   # ORD  
    "149.28.108.180"  # MIA
    "66.135.18.138"   # EWR
)

echo "Deploying BGP filter fix to prevent default route issues..."

for server in "${SERVERS[@]}"; do
    echo "Fixing $server..."
    
    # Create BGP filters
    ssh -i $SSH_KEY root@$server "cat > /etc/bird/bgp_filters.conf << 'EOF'
# BGP Import/Export Filters
# Only allow our announced prefixes, block default routes

filter ibgp_import {
  # Accept our IPv4 prefix
  if net = 192.30.120.0/23 then accept;
  # Accept our IPv6 prefix  
  if net = 2620:71:4000::/48 then accept;
  # Reject default routes and everything else
  if net = 0.0.0.0/0 then reject;
  if net = ::/0 then reject;
  reject;
}

filter ibgp_export {
  # Export our IPv4 prefix
  if net = 192.30.120.0/23 then accept;
  # Export our IPv6 prefix
  if net = 2620:71:4000::/48 then accept;
  # Reject everything else including default routes
  reject;
}
EOF"

    # Backup configs
    ssh -i $SSH_KEY root@$server "cp /etc/bird/bird.conf /etc/bird/bird.conf.backup && cp /etc/bird/ibgp.conf /etc/bird/ibgp.conf.backup"
    
    # Include filters in bird.conf
    ssh -i $SSH_KEY root@$server "sed -i '1i include \"/etc/bird/bgp_filters.conf\";' /etc/bird/bird.conf"
    
    # Fix kernel protocol exports  
    ssh -i $SSH_KEY root@$server "sed -i 's/export all;/export where source = RTS_BGP;/g' /etc/bird/bird.conf"
    
    # Apply filters to iBGP
    ssh -i $SSH_KEY root@$server "sed -i 's/import all;/import filter ibgp_import;/g' /etc/bird/ibgp.conf && sed -i 's/export all;/export filter ibgp_export;/g' /etc/bird/ibgp.conf"
    
    # Restart BIRD
    ssh -i $SSH_KEY root@$server "systemctl restart bird"
    
    echo "$server fixed"
done

echo "All nodes updated with BGP filters to prevent default route issues"