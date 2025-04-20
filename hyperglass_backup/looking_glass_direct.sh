#\!/bin/bash

# Set your server IP 
SERVER_IP="149.248.2.74"

echo "Setting up enhanced looking glass on $SERVER_IP..."

# Create the remote script
REMOTE_SCRIPT=$(cat << 'EOT'
#\!/bin/bash
set -e

# Create required directories
mkdir -p /var/www/looking-glass
mkdir -p /usr/local/bin

# Create BIRD proxy script
cat > /usr/local/bin/bird-proxy << 'EOS'
#\!/bin/bash
BIRD_SOCKET="/var/run/bird/bird.ctl"
# Find BIRD socket if not at the default location
if [ \! -S "$BIRD_SOCKET" ]; then
  FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null  < /dev/null |  head -1)
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

# Create HTML file
cat > /var/www/looking-glass/index.html << 'HTML'
<\!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>BGP Looking Glass</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            background-color: #f4f7f9;
            color: #333;
        }
        .header {
            background-color: #0098FF;
            color: white;
            padding: 20px;
            text-align: center;
        }
        .container {
            max-width: 960px;
            margin: 20px auto;
            padding: 0 20px;
        }
        .card {
            background-color: white;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 20px;
            overflow: hidden;
        }
        .card-header {
            background-color: #f9f9f9;
            padding: 15px 20px;
            border-bottom: 1px solid #eee;
            font-weight: bold;
        }
        .card-body {
            padding: 20px;
        }
        .status-info {
            background-color: #e6f7ff;
            border-left: 4px solid #0098FF;
            padding: 15px;
            margin-bottom: 20px;
        }
        .success {
            color: #00CC88;
        }
        .command {
            background-color: #f5f5f5;
            border-radius: 4px;
            padding: 10px 15px;
            font-family: monospace;
            margin: 10px 0;
            border-left: 3px solid #0098FF;
        }
        .output {
            background-color: #292929;
            color: #f1f1f1;
            border-radius: 4px;
            padding: 15px;
            font-family: monospace;
            white-space: pre-wrap;
            overflow-x: auto;
            margin: 10px 0;
        }
        .tabs {
            display: flex;
            border-bottom: 1px solid #ddd;
            margin-bottom: 20px;
        }
        .tab {
            padding: 10px 15px;
            cursor: pointer;
            border-bottom: 2px solid transparent;
        }
        .tab.active {
            border-bottom: 2px solid #0098FF;
            font-weight: bold;
        }
        .tab-content {
            display: none;
        }
        .tab-content.active {
            display: block;
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #f5f5f5;
        }
        tr:hover {
            background-color: #f9f9f9;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>BGP Looking Glass</h1>
        <p>Infinitum Nihil BGP Anycast Network (AS27218)</p>
    </div>
    
    <div class="container">
        <div class="status-info">
            <h3>✨ Welcome to our BGP Looking Glass</h3>
            <p>This looking glass provides visibility into our anycast BGP network powered by BIRD 2.16.2.</p>
        </div>
        
        <div class="tabs">
            <div class="tab active" onclick="openTab(event, 'overview')">Overview</div>
            <div class="tab" onclick="openTab(event, 'bgp-status')">BGP Status</div>
            <div class="tab" onclick="openTab(event, 'routes')">Route Information</div>
            <div class="tab" onclick="openTab(event, 'network')">Network Details</div>
        </div>
        
        <div id="overview" class="tab-content active">
            <div class="card">
                <div class="card-header">Network Overview</div>
                <div class="card-body">
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
                            <td><span class="success">✓ Active</span></td>
                            <td>Established with Vultr (AS64515)</td>
                        </tr>
                        <tr>
                            <td>IPv6 BGP Sessions</td>
                            <td><span class="success">✓ Active</span></td>
                            <td>Established with Vultr (AS64515)</td>
                        </tr>
                        <tr>
                            <td>Anycast IPv4</td>
                            <td><span class="success">✓ Announced</span></td>
                            <td>192.30.120.10/32</td>
                        </tr>
                        <tr>
                            <td>Anycast IPv6</td>
                            <td><span class="success">✓ Announced</span></td>
                            <td>2620:71:4000::c01e:780a/128</td>
                        </tr>
                        <tr>
                            <td>Path Prepending</td>
                            <td><span class="success">✓ Configured</span></td>
                            <td>Hierarchical (0x, 1x, 2x)</td>
                        </tr>
                    </table>
                </div>
            </div>
        </div>
        
        <div id="bgp-status" class="tab-content">
            <div class="card">
                <div class="card-header">BGP Protocol Status</div>
                <div class="card-body">
                    <div class="command">$ birdc show protocols</div>
                    <div class="output">BIRD 2.16.2 ready.
Name       Proto      Table      State  Since         Info
vultr4     BGP        ---        up     19:02:55      Established   
vultr6     BGP        ---        up     19:02:56      Established</div>
                    
                    <h3>BGP Protocol Details</h3>
                    <div class="command">$ birdc show protocols vultr4 all</div>
                    <div class="output">BIRD 2.16.2 ready.
Name       Proto      Table      State  Since         Info
vultr4     BGP        ---        up     19:02:55      Established   
  BGP state:          Established
    Neighbor address: 169.254.169.254
    Neighbor AS:      64515
    Local AS:         27218
    Neighbor ID:      169.254.169.254
    Local capabilities
      Multiprotocol
        AF announced: ipv4
      Route refresh
      Enhanced refresh
      Graceful restart
      4-octet AS numbers
      Extended messages
      Multiple paths
    Neighbor capabilities
      Multiprotocol
        AF announced: ipv4
      Route refresh
      Enhanced refresh
      Graceful restart
      4-octet AS numbers
      Extended messages
      Multiple paths
    Session:          external AS4
    Source address:   149.248.2.74
    Hold timer:       212/240
    Keepalive timer:  53/80
  Channel ipv4
    State:          UP
    Table:          master4
    Preference:     100
    Input filter:   ACCEPT
    Output filter:  export_bgp_filter
    Routes:         1 imported, 1 exported, 1 preferred
    Route change stats:     received   rejected   filtered    ignored   accepted
      Import updates:              1          0          0          0          1
      Import withdraws:            0          0        ---          0          0
      Export updates:              1          0          0        ---          1
      Export withdraws:            0        ---        ---        ---          0
    BGP Next hop:   149.248.2.74</div>
                </div>
            </div>
        </div>
        
        <div id="routes" class="tab-content">
            <div class="card">
                <div class="card-header">Anycast Routes</div>
                <div class="card-body">
                    <div class="command">$ birdc show route for 192.30.120.10</div>
                    <div class="output">192.30.120.10/32    unicast [direct1] * (240)
	dev dummy0</div>
                    
                    <div class="command">$ birdc show route for 2620:71:4000::c01e:780a</div>
                    <div class="output">2620:71:4000::c01e:780a/128 unicast [direct1] * (240)
	dev dummy0</div>
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
                            <td>45.76.76.125 (Floating)</td>
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
                    <table>
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
                            <td>Operating System</td>
                            <td>Ubuntu 22.04 LTS</td>
                        </tr>
                    </table>
                </div>
            </div>
        </div>
    </div>
    
    <script>
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
    </script>
</body>
</html>
HTML

# Configure Nginx
cat > /etc/nginx/conf.d/looking-glass.conf << 'EOC'
server {
    listen 80;
    listen [::]:80;
    server_name lg.infinitum-nihil.com;
    
    location / {
        root /var/www/looking-glass;
        index index.html;
        try_files $uri $uri/ =404;
    }
}
EOC

# Ensure Nginx can read the files
chown -R www-data:www-data /var/www/looking-glass

# Verify Nginx configuration
nginx -t && systemctl reload nginx

echo "Setup complete. The enhanced BGP looking glass is accessible at https://lg.infinitum-nihil.com"
EOT
)

# Use the password method to SSH and execute the script
sshpass -p YOUR_PASSWORD ssh -o StrictHostKeyChecking=no root@$SERVER_IP "bash -s" <<< "$REMOTE_SCRIPT"

echo "Script executed on $SERVER_IP - Looking Glass setup should be complete"
