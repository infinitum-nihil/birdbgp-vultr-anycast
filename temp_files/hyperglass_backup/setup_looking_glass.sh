#!/bin/bash
# Script to set up an enhanced static looking glass with real-time data updates
# This script creates an HTML/JS looking glass and sets up a cron job to keep the data fresh

# Server IP (the server where this will be deployed)
SERVER_IP="149.248.2.74"  # LAX server IP

# ANycast IPs 
ANYCAST_IPV4="192.30.120.10"
ANYCAST_IPV6="2620:71:4000::c01e:780a"

# Domain settings
DOMAIN="infinitum-nihil.com"
SUBDOMAIN="lg"

echo "Setting up enhanced looking glass on $SERVER_IP..."

# Create the remote script
cat > /tmp/deploy_looking_glass.sh << 'EOT'
#!/bin/bash
set -e

# Variables will be replaced by the main script
ANYCAST_IPV4="__ANYCAST_IPV4__"
ANYCAST_IPV6="__ANYCAST_IPV6__"
DOMAIN="__DOMAIN__"
SUBDOMAIN="__SUBDOMAIN__"

# Create required directories
mkdir -p /var/www/looking-glass/js
mkdir -p /usr/local/bin

# Install required packages if not already installed
apt-get update
apt-get install -y nginx socat certbot python3-certbot-nginx

# Create BIRD proxy script for data collection
cat > /usr/local/bin/bird-proxy << 'EOS'
#!/bin/bash
BIRD_SOCKET="/var/run/bird/bird.ctl"
# Find BIRD socket if not at the default location
if [ ! -S "$BIRD_SOCKET" ]; then
  FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null < /dev/null | head -1)
  if [ -n "$FOUND_SOCKET" ]; then
    BIRD_SOCKET="$FOUND_SOCKET"
  fi
fi
# Get command from stdin
read -r command
# Pass to BIRD socket using socat
echo "$command" | socat - UNIX-CONNECT:$BIRD_SOCKET
EOS

chmod +x /usr/local/bin/bird-proxy

# Set BIRD socket permissions
BIRD_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
if [ -S "$BIRD_SOCKET" ]; then
  echo "Found BIRD socket at $BIRD_SOCKET"
  chmod 666 "$BIRD_SOCKET"
  sed -i "s|/var/run/bird/bird.ctl|$BIRD_SOCKET|g" /usr/local/bin/bird-proxy
fi

# Create script to update BGP data
cat > /usr/local/bin/update-bird-data << 'EOS'
#!/bin/bash
# Script to update BGP data for the static looking glass

# Set server details
ANYCAST_IPV4="__ANYCAST_IPV4__"
ANYCAST_IPV6="__ANYCAST_IPV6__"
OUTPUT_DIR="/var/www/looking-glass/js"
OUTPUT_FILE="${OUTPUT_DIR}/bird-data.js"
TEMP_FILE="/tmp/bird-data.js.tmp"
BIRD_SOCKET="/run/bird/bird.ctl"

# Find BIRD socket if not at the default location
if [ ! -S "$BIRD_SOCKET" ]; then
  FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
  if [ -n "$FOUND_SOCKET" ]; then
    BIRD_SOCKET="$FOUND_SOCKET"
  fi
fi

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

# Collect and save the data
collect_bird_data

echo "BGP data updated at $(date)"
EOS

# Replace the placeholders with actual values
sed -i "s|__ANYCAST_IPV4__|$ANYCAST_IPV4|g" /usr/local/bin/update-bird-data
sed -i "s|__ANYCAST_IPV6__|$ANYCAST_IPV6|g" /usr/local/bin/update-bird-data

chmod +x /usr/local/bin/update-bird-data

# Create HTML file with dynamic data support
cat > /var/www/looking-glass/index.html << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>BGP Looking Glass</title>
    <style>
        :root {
            --primary-color: #0098FF;
            --secondary-color: #00CC88;
            --dark-bg: #292929;
            --light-bg: #f4f7f9;
            --card-bg: white;
            --header-bg: #f9f9f9;
            --border-color: #eee;
            --info-bg: #e6f7ff;
            --success-color: #00CC88;
            --error-color: #ff4757;
            --warning-color: #ffa502;
            --code-bg: #f5f5f5;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 0;
            background-color: var(--light-bg);
            color: #333;
            line-height: 1.6;
        }
        
        .header {
            background-color: var(--primary-color);
            color: white;
            padding: 20px;
            text-align: center;
            position: relative;
        }
        
        .container {
            max-width: 1100px;
            margin: 20px auto;
            padding: 0 20px;
        }
        
        .card {
            background-color: var(--card-bg);
            border-radius: 8px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            margin-bottom: 20px;
            overflow: hidden;
            transition: transform 0.3s ease;
        }
        
        .card:hover {
            transform: translateY(-5px);
        }
        
        .card-header {
            background-color: var(--header-bg);
            padding: 15px 20px;
            border-bottom: 1px solid var(--border-color);
            font-weight: bold;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .card-body {
            padding: 20px;
        }
        
        .status-info {
            background-color: var(--info-bg);
            border-left: 4px solid var(--primary-color);
            padding: 15px;
            margin-bottom: 20px;
            border-radius: 0 4px 4px 0;
        }
        
        .success {
            color: var(--success-color);
        }
        
        .error {
            color: var(--error-color);
        }
        
        .warning {
            color: var(--warning-color);
        }
        
        .command {
            background-color: var(--code-bg);
            border-radius: 4px;
            padding: 10px 15px;
            font-family: 'Courier New', Courier, monospace;
            margin: 10px 0;
            border-left: 3px solid var(--primary-color);
            overflow-x: auto;
        }
        
        .output {
            background-color: var(--dark-bg);
            color: #f1f1f1;
            border-radius: 4px;
            padding: 15px;
            font-family: 'Courier New', Courier, monospace;
            white-space: pre-wrap;
            overflow-x: auto;
            margin: 10px 0;
        }
        
        .tabs {
            display: flex;
            flex-wrap: wrap;
            border-bottom: 1px solid var(--border-color);
            margin-bottom: 20px;
        }
        
        .tab {
            padding: 10px 15px;
            cursor: pointer;
            border-bottom: 2px solid transparent;
            transition: all 0.3s ease;
            margin-right: 5px;
        }
        
        .tab:hover {
            background-color: rgba(0, 152, 255, 0.1);
        }
        
        .tab.active {
            border-bottom: 2px solid var(--primary-color);
            font-weight: bold;
            color: var(--primary-color);
        }
        
        .tab-content {
            display: none;
        }
        
        .tab-content.active {
            display: block;
            animation: fadeIn 0.5s;
        }
        
        @keyframes fadeIn {
            from { opacity: 0; }
            to { opacity: 1; }
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 15px 0;
        }
        
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid var(--border-color);
        }
        
        th {
            background-color: var(--code-bg);
            font-weight: bold;
        }
        
        tr:hover {
            background-color: rgba(0, 152, 255, 0.05);
        }
        
        .badge {
            display: inline-block;
            padding: 3px 8px;
            border-radius: 12px;
            font-size: 12px;
            font-weight: bold;
        }
        
        .badge-primary {
            background-color: var(--primary-color);
            color: white;
        }
        
        .badge-success {
            background-color: var(--success-color);
            color: white;
        }
        
        .badge-warning {
            background-color: var(--warning-color);
            color: white;
        }
        
        .refresh-btn {
            background-color: var(--secondary-color);
            color: white;
            border: none;
            padding: 8px 15px;
            border-radius: 4px;
            cursor: pointer;
            font-weight: bold;
            transition: background-color 0.3s;
        }
        
        .refresh-btn:hover {
            background-color: #00b377;
        }
        
        .timestamp {
            font-size: 13px;
            color: #666;
            margin-top: 20px;
            text-align: right;
            font-style: italic;
        }
        
        .copy-btn {
            background-color: #444;
            color: white;
            border: none;
            border-radius: 4px;
            padding: 5px 10px;
            font-size: 12px;
            cursor: pointer;
            float: right;
            transition: background-color 0.3s;
        }
        
        .copy-btn:hover {
            background-color: #555;
        }
        
        .copied {
            background-color: var(--success-color);
        }
        
        @media (max-width: 768px) {
            .container {
                padding: 0 10px;
            }
            
            .tabs {
                flex-direction: column;
            }
            
            .tab {
                width: 100%;
                text-align: center;
                padding: 10px 0;
            }
            
            table {
                font-size: 14px;
            }
            
            th, td {
                padding: 8px 10px;
            }
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>BGP Looking Glass</h1>
        <p>Infinitum Nihil BGP Anycast Network (AS27218)</p>
    </div>
    
    <div class="container">
        <div class="status-info" id="status-banner">
            <h3>✨ Welcome to our BGP Looking Glass</h3>
            <p>This looking glass provides visibility into our anycast BGP network powered by BIRD 2.16.2.</p>
            <div id="update-status">Data last updated: <span id="last-update">Loading...</span></div>
        </div>
        
        <div class="tabs">
            <div class="tab active" onclick="openTab(event, 'overview')">Overview</div>
            <div class="tab" onclick="openTab(event, 'bgp-status')">BGP Status</div>
            <div class="tab" onclick="openTab(event, 'routes')">Route Information</div>
            <div class="tab" onclick="openTab(event, 'network')">Network Details</div>
            <div class="tab" onclick="openTab(event, 'memory')">Memory Usage</div>
        </div>
        
        <div id="overview" class="tab-content active">
            <div class="card">
                <div class="card-header">
                    Network Overview
                    <button class="refresh-btn" onclick="refreshData()">Refresh Data</button>
                </div>
                <div class="card-body">
                    <div id="bird-status" class="command">Loading BIRD status...</div>
                    
                    <p>Our anycast network consists of strategically placed nodes that announce the same IP prefixes from multiple locations. This enables:</p>
                    <ul>
                        <li>Reduced latency by routing users to the closest server</li>
                        <li>Improved availability through geographic redundancy</li>
                        <li>Resilience against DDoS attacks through traffic distribution</li>
                    </ul>
                    
                    <h3>Network Status Summary</h3>
                    <table>
                        <tr>
                            <th>Component</th>
                            <th>Status</th>
                            <th>Details</th>
                        </tr>
                        <tr>
                            <td>IPv4 BGP Sessions</td>
                            <td><span id="ipv4-status" class="badge badge-success">Checking...</span></td>
                            <td>With Vultr (AS64515)</td>
                        </tr>
                        <tr>
                            <td>IPv6 BGP Sessions</td>
                            <td><span id="ipv6-status" class="badge badge-success">Checking...</span></td>
                            <td>With Vultr (AS64515)</td>
                        </tr>
                        <tr>
                            <td>Anycast IPv4</td>
                            <td><span id="ipv4-route-status" class="badge badge-success">Checking...</span></td>
                            <td>192.30.120.10/32</td>
                        </tr>
                        <tr>
                            <td>Anycast IPv6</td>
                            <td><span id="ipv6-route-status" class="badge badge-success">Checking...</span></td>
                            <td>2620:71:4000::c01e:780a/128</td>
                        </tr>
                    </table>
                    
                    <div class="timestamp">System: <span id="system-info">Loading system info...</span></div>
                </div>
            </div>
        </div>
        
        <div id="bgp-status" class="tab-content">
            <div class="card">
                <div class="card-header">
                    BGP Protocol Status
                    <button class="refresh-btn" onclick="refreshData()">Refresh Data</button>
                </div>
                <div class="card-body">
                    <div class="command">
                        birdc show protocols
                        <button class="copy-btn" onclick="copyToClipboard(this, 'protocols-output')">Copy</button>
                    </div>
                    <div id="protocols-output" class="output">Loading protocol data...</div>
                    
                    <h3>IPv4 BGP Protocol Details</h3>
                    <div class="command">
                        birdc show protocols vultr4 all
                        <button class="copy-btn" onclick="copyToClipboard(this, 'ipv4-output')">Copy</button>
                    </div>
                    <div id="ipv4-output" class="output">Loading IPv4 BGP data...</div>
                    
                    <h3>IPv6 BGP Protocol Details</h3>
                    <div class="command">
                        birdc show protocols vultr6 all
                        <button class="copy-btn" onclick="copyToClipboard(this, 'ipv6-output')">Copy</button>
                    </div>
                    <div id="ipv6-output" class="output">Loading IPv6 BGP data...</div>
                </div>
            </div>
        </div>
        
        <div id="routes" class="tab-content">
            <div class="card">
                <div class="card-header">
                    Anycast Routes
                    <button class="refresh-btn" onclick="refreshData()">Refresh Data</button>
                </div>
                <div class="card-body">
                    <h3>IPv4 Anycast Route</h3>
                    <div class="command">
                        birdc show route for 192.30.120.10
                        <button class="copy-btn" onclick="copyToClipboard(this, 'ipv4-route-output')">Copy</button>
                    </div>
                    <div id="ipv4-route-output" class="output">Loading IPv4 route data...</div>
                    
                    <h3>IPv6 Anycast Route</h3>
                    <div class="command">
                        birdc show route for 2620:71:4000::c01e:780a
                        <button class="copy-btn" onclick="copyToClipboard(this, 'ipv6-route-output')">Copy</button>
                    </div>
                    <div id="ipv6-route-output" class="output">Loading IPv6 route data...</div>
                    
                    <h3>IPv4 Exported Routes</h3>
                    <div class="command">
                        birdc show route export vultr4
                        <button class="copy-btn" onclick="copyToClipboard(this, 'ipv4-exported-output')">Copy</button>
                    </div>
                    <div id="ipv4-exported-output" class="output">Loading IPv4 exported routes...</div>
                    
                    <h3>IPv6 Exported Routes</h3>
                    <div class="command">
                        birdc show route export vultr6
                        <button class="copy-btn" onclick="copyToClipboard(this, 'ipv6-exported-output')">Copy</button>
                    </div>
                    <div id="ipv6-exported-output" class="output">Loading IPv6 exported routes...</div>
                </div>
            </div>
            
            <div class="card">
                <div class="card-header">Path Prepending Configuration</div>
                <div class="card-body">
                    <p>Our network uses hierarchical path prepending to control traffic flow:</p>
                    <ul>
                        <li>Primary (LAX): No prepends (0x) - preferred for all traffic</li>
                        <li>Secondary (EWR): Single prepend (1x) - first failover</li>
                        <li>Tertiary (MIA): Double prepend (2x) - second failover</li>
                        <li>Quaternary (ORD): Double prepend (2x) - third failover</li>
                    </ul>
                </div>
            </div>
        </div>
        
        <div id="network" class="tab-content">
            <div class="card">
                <div class="card-header">Network Information</div>
                <div class="card-body">
                    <h3>Server Locations</h3>
                    <table>
                        <tr>
                            <th>Role</th>
                            <th>Location</th>
                            <th>IP Address</th>
                            <th>Path Prepend</th>
                        </tr>
                        <tr>
                            <td>Primary</td>
                            <td>LAX (Los Angeles)</td>
                            <td>149.248.2.74</td>
                            <td>None (0x)</td>
                        </tr>
                        <tr>
                            <td>Secondary</td>
                            <td>EWR (New York/New Jersey)</td>
                            <td>149.28.224.120</td>
                            <td>Single (1x)</td>
                        </tr>
                        <tr>
                            <td>Tertiary</td>
                            <td>MIA (Miami)</td>
                            <td>149.28.243.56</td>
                            <td>Double (2x)</td>
                        </tr>
                        <tr>
                            <td>Quaternary</td>
                            <td>ORD (Chicago)</td>
                            <td>149.28.57.168</td>
                            <td>Double (2x)</td>
                        </tr>
                    </table>
                    
                    <h3>Anycast Addresses</h3>
                    <table>
                        <tr>
                            <th>Type</th>
                            <th>Address</th>
                            <th>CIDR</th>
                            <th>Interface</th>
                        </tr>
                        <tr>
                            <td>IPv4 Anycast</td>
                            <td>192.30.120.10</td>
                            <td>/32</td>
                            <td>dummy0</td>
                        </tr>
                        <tr>
                            <td>IPv6 Anycast</td>
                            <td>2620:71:4000::c01e:780a</td>
                            <td>/128</td>
                            <td>dummy0</td>
                        </tr>
                    </table>
                    
                    <h3>System Information</h3>
                    <table id="system-table">
                        <tr>
                            <th>Component</th>
                            <th>Value</th>
                        </tr>
                        <tr>
                            <td>BGP ASN</td>
                            <td>27218</td>
                        </tr>
                        <tr>
                            <td>BGP Daemon</td>
                            <td>BIRD 2.16.2</td>
                        </tr>
                        <tr>
                            <td>Hostname</td>
                            <td id="sys-hostname">Loading...</td>
                        </tr>
                        <tr>
                            <td>Operating System</td>
                            <td id="sys-os">Loading...</td>
                        </tr>
                        <tr>
                            <td>Kernel</td>
                            <td id="sys-kernel">Loading...</td>
                        </tr>
                        <tr>
                            <td>Uptime</td>
                            <td id="sys-uptime">Loading...</td>
                        </tr>
                        <tr>
                            <td>Load Average</td>
                            <td id="sys-load">Loading...</td>
                        </tr>
                    </table>
                </div>
            </div>
        </div>
        
        <div id="memory" class="tab-content">
            <div class="card">
                <div class="card-header">
                    BIRD Memory Usage
                    <button class="refresh-btn" onclick="refreshData()">Refresh Data</button>
                </div>
                <div class="card-body">
                    <div class="command">
                        birdc show memory
                        <button class="copy-btn" onclick="copyToClipboard(this, 'memory-output')">Copy</button>
                    </div>
                    <div id="memory-output" class="output">Loading memory usage data...</div>
                </div>
            </div>
        </div>
    </div>
    
    <script src="js/bird-data.js"></script>
    <script>
        // Function to open tabs
        function openTab(evt, tabName) {
            // Hide all tab content
            const tabContents = document.getElementsByClassName("tab-content");
            for (let i = 0; i < tabContents.length; i++) {
                tabContents[i].className = tabContents[i].className.replace(" active", "");
            }
            
            // Remove active class from all tabs
            const tabs = document.getElementsByClassName("tab");
            for (let i = 0; i < tabs.length; i++) {
                tabs[i].className = tabs[i].className.replace(" active", "");
            }
            
            // Show the current tab and add active class
            document.getElementById(tabName).className += " active";
            evt.currentTarget.className += " active";
        }
        
        // Function to copy text to clipboard
        function copyToClipboard(button, elementId) {
            const text = document.getElementById(elementId).innerText;
            navigator.clipboard.writeText(text).then(() => {
                button.textContent = "Copied!";
                button.classList.add("copied");
                setTimeout(() => {
                    button.textContent = "Copy";
                    button.classList.remove("copied");
                }, 2000);
            });
        }
        
        // Function to update the UI with BGP data
        function updateUI(data) {
            if (!data) {
                console.error("No data available");
                return;
            }
            
            // Update status
            document.getElementById("bird-status").innerText = data.status.split('\n')[0];
            
            // Update protocols
            document.getElementById("protocols-output").innerText = data.protocols;
            
            // Update IPv4 and IPv6 BGP details
            document.getElementById("ipv4-output").innerText = data.ipv4_bgp;
            document.getElementById("ipv6-output").innerText = data.ipv6_bgp;
            
            // Update routes
            document.getElementById("ipv4-route-output").innerText = data.ipv4_route;
            document.getElementById("ipv6-route-output").innerText = data.ipv6_route;
            document.getElementById("ipv4-exported-output").innerText = data.ipv4_exported;
            document.getElementById("ipv6-exported-output").innerText = data.ipv6_exported;
            
            // Update memory
            document.getElementById("memory-output").innerText = data.memory;
            
            // Update status indicators
            const ipv4Status = data.ipv4_bgp.includes("Established") ? 
                '<span class="badge badge-success">Active</span>' : 
                '<span class="badge badge-warning">Down</span>';
            document.getElementById("ipv4-status").outerHTML = ipv4Status;
            
            const ipv6Status = data.ipv6_bgp.includes("Established") ? 
                '<span class="badge badge-success">Active</span>' : 
                '<span class="badge badge-warning">Down</span>';
            document.getElementById("ipv6-status").outerHTML = ipv6Status;
            
            const ipv4RouteStatus = data.ipv4_route.includes(data.ipv4_route) ? 
                '<span class="badge badge-success">Announced</span>' : 
                '<span class="badge badge-warning">Not Announced</span>';
            document.getElementById("ipv4-route-status").outerHTML = ipv4RouteStatus;
            
            const ipv6RouteStatus = data.ipv6_route.includes(data.ipv6_route) ? 
                '<span class="badge badge-success">Announced</span>' : 
                '<span class="badge badge-warning">Not Announced</span>';
            document.getElementById("ipv6-route-status").outerHTML = ipv6RouteStatus;
            
            // Update system information
            if (data.system) {
                document.getElementById("system-info").innerText = `${data.system.hostname} | ${data.system.os} | ${data.system.uptime}`;
                document.getElementById("sys-hostname").innerText = data.system.hostname;
                document.getElementById("sys-os").innerText = data.system.os;
                document.getElementById("sys-kernel").innerText = data.system.kernel;
                document.getElementById("sys-uptime").innerText = data.system.uptime;
                document.getElementById("sys-load").innerText = data.system.load;
                document.getElementById("last-update").innerText = data.system.updated;
            }
        }
        
        // Function to refresh data
        function refreshData() {
            // Display loading indicator
            document.getElementById("last-update").innerText = "Refreshing...";
            
            // We're using a JavaScript file that gets updated every 5 minutes
            // So we just need to reload the script
            const oldScript = document.querySelector('script[src="js/bird-data.js"]');
            if (oldScript) {
                oldScript.remove();
            }
            
            const newScript = document.createElement('script');
            newScript.src = 'js/bird-data.js?' + new Date().getTime(); // Add timestamp to prevent caching
            newScript.onload = function() {
                if (typeof birdData !== 'undefined') {
                    updateUI(birdData);
                } else {
                    console.error("birdData not defined after script reload");
                }
            };
            document.body.appendChild(newScript);
        }
        
        // Initialize data when page loads
        window.onload = function() {
            if (typeof birdData !== 'undefined') {
                updateUI(birdData);
            } else {
                console.error("birdData not defined on page load");
                // Fallback - try to load the script
                refreshData();
            }
            
            // Set timer to update data automatically every 5 minutes
            setInterval(refreshData, 300000); // 5 minutes
        };
    </script>
</body>
</html>
HTML

# Create nginx configuration
cat > /etc/nginx/conf.d/looking-glass.conf << EOC
server {
    listen 80;
    listen [::]:80;
    server_name ${SUBDOMAIN}.${DOMAIN};
    
    location / {
        root /var/www/looking-glass;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOC

# Ensure nginx can read the files
chown -R www-data:www-data /var/www/looking-glass

# Verify nginx configuration
nginx -t && systemctl reload nginx

# Set up SSL with Let's Encrypt
certbot --nginx -d ${SUBDOMAIN}.${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN}

# Create cron job to update data every 5 minutes
echo "*/5 * * * * root /usr/local/bin/update-bird-data > /var/log/bird-data-update.log 2>&1" > /etc/cron.d/update-bird-data
chmod 644 /etc/cron.d/update-bird-data

# Run initial data update
/usr/local/bin/update-bird-data

echo "Setup complete. The enhanced BGP looking glass is accessible at https://${SUBDOMAIN}.${DOMAIN}"
echo "Data will be updated automatically every 5 minutes."
EOT

# Replace the placeholders
sed -i "s/__ANYCAST_IPV4__/$ANYCAST_IPV4/g" /tmp/deploy_looking_glass.sh
sed -i "s/__ANYCAST_IPV6__/$ANYCAST_IPV6/g" /tmp/deploy_looking_glass.sh
sed -i "s/__DOMAIN__/$DOMAIN/g" /tmp/deploy_looking_glass.sh
sed -i "s/__SUBDOMAIN__/$SUBDOMAIN/g" /tmp/deploy_looking_glass.sh

# Make the script executable
chmod +x /tmp/deploy_looking_glass.sh

echo -e "\nScript created at /tmp/deploy_looking_glass.sh and ready to deploy."
echo "To deploy the looking glass on the LAX server, run:"
echo "scp /tmp/deploy_looking_glass.sh root@$SERVER_IP:/tmp/"
echo "ssh root@$SERVER_IP 'bash /tmp/deploy_looking_glass.sh'"
echo -e "\nThe looking glass will be accessible at https://$SUBDOMAIN.$DOMAIN"