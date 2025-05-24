#\!/bin/bash

# Manual BGP node bootstrap with self-registration
SERVICE_DISCOVERY_URL="http://149.248.2.74:5000"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"  < /dev/null |  tee -a /var/log/manual-bootstrap.log
}

log "Starting manual BGP node bootstrap with self-registration..."

# Get external IPs
EXTERNAL_IPV4=$(curl -4 -s icanhazip.com 2>/dev/null || echo "")
EXTERNAL_IPV6=$(curl -6 -s icanhazip.com 2>/dev/null || echo "")
log "External IPv4: $EXTERNAL_IPV4"
log "External IPv6: $EXTERNAL_IPV6"

# Register with service discovery API first
log "Registering with service discovery API..."
REGISTER_RESPONSE=$(curl -s -X POST "$SERVICE_DISCOVERY_URL/api/v1/nodes/register" \
                   -H "Content-Type: application/json" \
                   -d "{\"external_ip\": \"$EXTERNAL_IPV4\", \"external_ipv6\": \"$EXTERNAL_IPV6\"}")

log "Registration response: $REGISTER_RESPONSE"

# Check registration success
REG_STATUS=$(echo "$REGISTER_RESPONSE" | jq -r '.status // "failed"')
if [ "$REG_STATUS" \!= "registered" ] && [ "$REG_STATUS" \!= "updated" ]; then
    log "ERROR: Registration failed - $REGISTER_RESPONSE"
    exit 1
fi

log "Successfully registered with service discovery API"

# Now run the normal cloud-init bootstrap
/usr/bin/cloud-init single --name final

log "Manual bootstrap completed"
