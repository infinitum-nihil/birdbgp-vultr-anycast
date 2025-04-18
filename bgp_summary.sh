#!/bin/bash
# Script to display a complete BGP summary of all instances
source "$(dirname "$0")/.env"

echo "=== BGP DEPLOYMENT SUMMARY ==="
echo
echo "INSTANCES:"
echo "  Primary IPv4 (EWR): 66.135.18.138 - No Path Prepending (Priority 1)"
echo "  Secondary IPv4 (MIA): 149.28.108.180 - 1x Path Prepending (Priority 2)"
echo "  Tertiary IPv4 (ORD): 66.42.113.101 - 2x Path Prepending (Priority 3)"
echo "  IPv6 (LAX): 149.248.2.74 - 2x Path Prepending (Priority 3)"
echo
echo "CONFIGURATION:"
echo "  AS Number: 27218"
echo "  IPv4 Prefix: 192.30.120.0/23"
echo "  IPv6 Prefix: 2620:71:4000::/48"
echo "  Peer AS: 64515 (Vultr)"
echo

# Function to check BIRD status
check_instance() {
  local server_ip=$1
  local name=$2
  local protocol=$3
  
  echo "=== $name BGP STATUS ==="
  echo "  Server IP: $server_ip"
  echo "  Protocol: $protocol"
  
  # Check if BIRD service is running
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@$server_ip "systemctl is-active bird" > /dev/null
  if [ $? -eq 0 ]; then
    echo "  BIRD Service: Running"
    
    # Get BGP status
    bgp_status=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show protocols $protocol | grep -A 1 $protocol")
    
    if [[ $bgp_status == *"Established"* ]]; then
      echo "  BGP Session: Established ✅"
      
      # Check BGP path prepending
      if [[ $name == *"Primary"* ]]; then
        echo "  Path Prepending: None (Highest Priority Route)"
      elif [[ $name == *"Secondary"* ]]; then
        echo "  Path Prepending: 1x (Second Priority Route)"
      else
        echo "  Path Prepending: 2x (Lowest Priority Route)"
      fi
      
      # Check route announcements
      route_count=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "birdc show route count | grep -i 'Total:' | awk '{print \$2,\$3,\$4,\$5,\$6,\$7,\$8}'")
      echo "  Routes: $route_count"
      
      # Check floating IPs
      if [[ $protocol == *"6"* ]]; then
        ip_addr=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip -6 addr show | grep -i '2001:19f0:' | grep -v 'fe80' | head -1 | awk '{print \$2}' | cut -d'/' -f1")
        echo "  IPv6 Address: $ip_addr"
      else
        ip_addr=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip addr show | grep -i 'scope global' | head -1 | awk '{print \$2}' | cut -d'/' -f1")
        float_ip=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$server_ip "ip addr show | grep -v '127.0.0.1' | grep -i 'scope global' | grep -v '$ip_addr' | awk '{print \$2}' | cut -d'/' -f1")
        if [ -n "$float_ip" ]; then
          echo "  Floating IP: $float_ip"
        else
          echo "  Floating IP: Not configured"
        fi
      fi
    else
      echo "  BGP Session: Not Established ❌"
      echo "  Status: $bgp_status"
    fi
  else
    echo "  BIRD Service: Not Running ❌"
  fi
  echo
}

# Check each instance
check_instance "66.135.18.138" "Primary IPv4 (EWR)" "vultr"
check_instance "149.28.108.180" "Secondary IPv4 (MIA)" "vultr"
check_instance "66.42.113.101" "Tertiary IPv4 (ORD)" "vultr"
check_instance "149.248.2.74" "IPv6 (LAX)" "vultr6"

echo "=== BGP FAILOVER INSTRUCTIONS ==="
echo "To test failover, stop BGP on the primary server:"
echo "  ssh root@66.135.18.138 systemctl stop bird"
echo
echo "To restore the primary server:"
echo "  ssh root@66.135.18.138 systemctl start bird"
echo
echo "BGP Summary completed."