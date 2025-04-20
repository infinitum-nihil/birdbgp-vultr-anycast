#!/bin/bash
# Script to update BGP data for the static looking glass
# This script collects current BGP data and generates a JavaScript file

# Set server details
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"
OUTPUT_DIR="/var/www/looking-glass/js"
OUTPUT_FILE="${OUTPUT_DIR}/bird-data.js"
TEMP_FILE="/tmp/bird-data.js.tmp"
BIRD_SOCKET="/run/bird/bird.ctl"

# Create directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Function to escape special characters for JavaScript
escape_for_js() {
  # Escape backslashes, then escape quotes and newlines
  echo "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/`/\\`/g' | sed ':a;N;$!ba;s/\n/\\n/g'
}

# Function to collect BIRD data
collect_bird_data() {
  # Create the JavaScript file header
  cat > "$TEMP_FILE" << EOF
// Static BIRD data for the looking glass
// Last updated: $(date)
const birdData = {
EOF

  # Get BIRD status
  BIRD_STATUS=$(echo "show status" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  BIRD_STATUS_JS=$(escape_for_js "$BIRD_STATUS")

  echo "  status: \`$BIRD_STATUS_JS\`," >> "$TEMP_FILE"

  # Get BGP summary
  BGP_SUMMARY=$(echo "show protocols" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  BGP_SUMMARY_JS=$(escape_for_js "$BGP_SUMMARY")

  echo "  protocols: \`$BGP_SUMMARY_JS\`," >> "$TEMP_FILE"

  # Get IPv4 BGP details
  IPV4_BGP=$(echo "show protocols vultr4 all" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  IPV4_BGP_JS=$(escape_for_js "$IPV4_BGP")

  echo "  ipv4_bgp: \`$IPV4_BGP_JS\`," >> "$TEMP_FILE"

  # Get IPv6 BGP details
  IPV6_BGP=$(echo "show protocols vultr6 all" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  IPV6_BGP_JS=$(escape_for_js "$IPV6_BGP")

  echo "  ipv6_bgp: \`$IPV6_BGP_JS\`," >> "$TEMP_FILE"

  # Get IPv4 anycast route
  IPV4_ROUTE=$(echo "show route for $ANYCAST_IPV4" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  IPV4_ROUTE_JS=$(escape_for_js "$IPV4_ROUTE")

  echo "  ipv4_route: \`$IPV4_ROUTE_JS\`," >> "$TEMP_FILE"

  # Get IPv6 anycast route
  IPV6_ROUTE=$(echo "show route for $ANYCAST_IPV6" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  IPV6_ROUTE_JS=$(escape_for_js "$IPV6_ROUTE")

  echo "  ipv6_route: \`$IPV6_ROUTE_JS\`," >> "$TEMP_FILE"

  # Get IPv4 exported routes 
  IPV4_EXPORTED=$(echo "show route export vultr4" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  IPV4_EXPORTED_JS=$(escape_for_js "$IPV4_EXPORTED")

  echo "  ipv4_exported: \`$IPV4_EXPORTED_JS\`," >> "$TEMP_FILE"

  # Get IPv6 exported routes
  IPV6_EXPORTED=$(echo "show route export vultr6" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  IPV6_EXPORTED_JS=$(escape_for_js "$IPV6_EXPORTED")

  echo "  ipv6_exported: \`$IPV6_EXPORTED_JS\`," >> "$TEMP_FILE"

  # Get memory usage
  MEMORY_USAGE=$(echo "show memory" | socat - UNIX-CONNECT:$BIRD_SOCKET 2>/dev/null)
  MEMORY_USAGE_JS=$(escape_for_js "$MEMORY_USAGE")

  echo "  memory: \`$MEMORY_USAGE_JS\`," >> "$TEMP_FILE"

  # Get system information
  HOSTNAME=$(hostname)
  KERNEL=$(uname -r)
  OS=$(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)
  UPTIME=$(uptime -p)
  LOAD=$(uptime | sed 's/.*load average: //')

  # JSON structure for system info
  cat >> "$TEMP_FILE" << EOF
  system: {
    hostname: "$HOSTNAME",
    os: "$OS",
    kernel: "$KERNEL",
    uptime: "$UPTIME",
    load: "$LOAD",
    updated: "$(date)"
  }
};
EOF

  # Move temporary file to final location
  mv "$TEMP_FILE" "$OUTPUT_FILE"
  chmod 644 "$OUTPUT_FILE"
}

# Check if BIRD socket exists
if [ ! -S "$BIRD_SOCKET" ]; then
  echo "Error: BIRD socket not found at $BIRD_SOCKET"
  # Try to find it elsewhere
  FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
  if [ -n "$FOUND_SOCKET" ]; then
    echo "Found BIRD socket at $FOUND_SOCKET"
    BIRD_SOCKET="$FOUND_SOCKET"
  else
    echo "Error: No BIRD socket found."
    exit 1
  fi
fi

# Collect and save the data
collect_bird_data

echo "BGP data updated at $(date)"