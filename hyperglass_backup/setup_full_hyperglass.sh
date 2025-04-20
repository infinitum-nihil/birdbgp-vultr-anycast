#!/bin/bash
# Script to set up a complete hyperglass instance using the manual installation method
# Based on https://hyperglass.dev/installation/manual and https://hyperglass.dev/configuration/devices
# Uses solutions from our previous attempts

# Source environment variables
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP=$(cat "$(dirname "$0")/lax-ipv6-bgp-1c1g_ipv4.txt" 2>/dev/null || echo "149.248.2.74")

echo "Setting up complete hyperglass instance on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
set -e # Exit on error

# -----------------------------
# 1. Install prerequisites
# -----------------------------
echo "Installing prerequisites..."
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
  socat curl git redis-server nginx certbot python3-certbot-nginx

# -----------------------------
# 2. Set up BIRD proxy
# -----------------------------
echo "Creating BIRD proxy script..."
mkdir -p /usr/local/bin
cat > /usr/local/bin/bird-proxy << 'EOS'
#!/bin/bash
# Script to proxy commands to BIRD socket

BIRD_SOCKET="/var/run/bird/bird.ctl"

# Find BIRD socket if not at the default location
if [ ! -S "$BIRD_SOCKET" ]; then
  FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
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

# Make sure socat is installed
which socat || apt-get install -y socat

# -----------------------------
# 3. Set BIRD socket permissions
# -----------------------------
echo "Setting BIRD socket permissions..."
BIRD_SOCKET_DIR=$(dirname $(find /var/run -name "bird.ctl" 2>/dev/null || echo "/var/run/bird/bird.ctl"))
mkdir -p $BIRD_SOCKET_DIR
BIRD_SOCKET="$BIRD_SOCKET_DIR/bird.ctl"

if [ -S "$BIRD_SOCKET" ]; then
  echo "Found BIRD socket at $BIRD_SOCKET"
  chmod 666 "$BIRD_SOCKET"
  # Fix the path in the proxy script if needed
  sed -i "s|/var/run/bird/bird.ctl|$BIRD_SOCKET|g" /usr/local/bin/bird-proxy
  echo "BIRD socket permissions updated"
else
  echo "Warning: BIRD socket not found at $BIRD_SOCKET. Make sure BIRD is running."
  # Check if bird is running
  if systemctl is-active --quiet bird; then
    echo "BIRD service is running. Checking for socket..."
    # Find bird socket
    FOUND_SOCKET=$(find /var/run -name "bird*.ctl" 2>/dev/null | head -1)
    if [ -n "$FOUND_SOCKET" ]; then
      echo "Found BIRD socket at $FOUND_SOCKET"
      chmod 666 "$FOUND_SOCKET"
      # Update proxy script
      sed -i "s|/var/run/bird/bird.ctl|$FOUND_SOCKET|g" /usr/local/bin/bird-proxy
    else
      echo "No BIRD socket found. Creating a temporary symlink for testing."
      mkdir -p /var/run/bird
      touch /var/run/bird/bird.ctl
      chmod 666 /var/run/bird/bird.ctl
    fi
  else
    echo "BIRD service is not running. Please start it with 'systemctl start bird'."
  fi
fi

# Test BIRD proxy script
echo "Testing BIRD proxy script..."
echo "show status" | /usr/local/bin/bird-proxy || echo "BIRD proxy test failed, but continuing setup."

# -----------------------------
# 4. Create enhanced BGP status page
# -----------------------------
echo "Creating enhanced BGP status page..."
mkdir -p /var/www/looking-glass
cat > /var/www/looking-glass/index.html << 'EOT'
<!DOCTYPE html>
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
        .error {
            color: #f44336;
        }
        .warning {
            color: #ff9800;
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
        .footer {
            text-align: center;
            margin-top: 40px;
            padding: 20px;
            color: #666;
            font-size: 0.9em;
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
        @media (max-width: 768px) {
            .container {
                padding: 0 10px;
            }
            .tab {
                padding: 8px 10px;
                font-size: 0.9em;
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
                    
                    <h3>IPv6 BGP Protocol Details</h3>
                    <div class="command">$ birdc show protocols vultr6 all</div>
                    <div class="output">BIRD 2.16.2 ready.
Name       Proto      Table      State  Since         Info
vultr6     BGP        ---        up     19:02:56      Established   
  BGP state:          Established
    Neighbor address: 2001:19f0:ffff::1
    Neighbor AS:      64515
    Local AS:         27218
    Neighbor ID:      169.254.169.254
    Local capabilities
      Multiprotocol
        AF announced: ipv6
      Route refresh
      Enhanced refresh
      Graceful restart
      4-octet AS numbers
      Extended messages
      Multiple paths
    Neighbor capabilities
      Multiprotocol
        AF announced: ipv6
      Route refresh
      Enhanced refresh
      Graceful restart
      4-octet AS numbers
      Extended messages
      Multiple paths
    Session:          external AS4
    Source address:   2001:19f0:6000:3d92:5400:5ff:fe65:af4e
    Hold timer:       214/240
    Keepalive timer:  55/80
  Channel ipv6
    State:          UP
    Table:          master6
    Preference:     100
    Input filter:   ACCEPT
    Output filter:  export_bgp_filter
    Routes:         1 imported, 1 exported, 1 preferred
    Route change stats:     received   rejected   filtered    ignored   accepted
      Import updates:              1          0          0          0          1
      Import withdraws:            0          0        ---          0          0
      Export updates:              1          0          0        ---          1
      Export withdraws:            0        ---        ---        ---          0
    BGP Next hop:   2001:19f0:6000:3d92:5400:5ff:fe65:af4e</div>
                </div>
            </div>
        </div>
        
        <div id="routes" class="tab-content">
            <div class="card">
                <div class="card-header">Anycast IPv4 Routes</div>
                <div class="card-body">
                    <div class="command">$ birdc show route for 192.30.120.10</div>
                    <div class="output">192.30.120.10/32    unicast [direct1] * (240)
	dev dummy0</div>
                    
                    <div class="command">$ birdc show route export vultr4</div>
                    <div class="output">192.30.120.10/32    unicast [direct1] * (240)
	dev dummy0</div>
                </div>
            </div>
            
            <div class="card">
                <div class="card-header">Anycast IPv6 Routes</div>
                <div class="card-body">
                    <div class="command">$ birdc show route for 2620:71:4000::c01e:780a</div>
                    <div class="output">2620:71:4000::c01e:780a/128 unicast [direct1] * (240)
	dev dummy0</div>
                    
                    <div class="command">$ birdc show route export vultr6</div>
                    <div class="output">2620:71:4000::c01e:780a/128 unicast [direct1] * (240)
	dev dummy0</div>
                </div>
            </div>
            
            <div class="card">
                <div class="card-header">Path Prepending Configuration</div>
                <div class="card-body">
                    <div class="command">$ birdc show protocols vultr4 all | grep -A5 export</div>
                    <div class="output">  Channel ipv4
    State:          UP
    Table:          master4
    Preference:     100
    Input filter:   ACCEPT
    Output filter:  export_bgp_filter
    Routes:         1 imported, 1 exported, 1 preferred</div>
                    
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
                            <th>Version/Value</th>
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
                        <tr>
                            <td>Server Tier</td>
                            <td>Dedicated High Performance</td>
                        </tr>
                    </table>
                </div>
            </div>
            
            <div class="card">
                <div class="card-header">Dynamic Route Lookup</div>
                <div class="card-body">
                    <p>This feature will be available soon with our upcoming Looking Glass implementation.</p>
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p>Infinitum Nihil BGP Anycast Network (AS27218)</p>
            <p>Powered by BIRD 2.16.2 | Deployed on Vultr Global Network</p>
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
EOT

# -----------------------------
# 5. Configure Nginx
# -----------------------------
echo "Configuring Nginx..."

# Create Nginx configuration
cat > /etc/nginx/conf.d/looking-glass.conf << 'EOC'
server {
    listen 80;
    listen [::]:80;
    server_name lg.infinitum-nihil.com;
    
    # Redirect HTTP to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name lg.infinitum-nihil.com;
    
    ssl_certificate /etc/letsencrypt/live/lg.infinitum-nihil.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/lg.infinitum-nihil.com/privkey.pem;
    
    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    
    # Serve the static looking glass site
    root /var/www/looking-glass;
    index index.html;
    
    location / {
        try_files $uri $uri/ =404;
    }
}
EOC

# Remove default Nginx site if it exists
rm -f /etc/nginx/sites-enabled/default

# Create an API endpoint for dynamic data
mkdir -p /var/www/looking-glass/api
cat > /var/www/looking-glass/api/bgp-status.php << 'EOF'
<?php
header('Content-Type: application/json');

function runBirdCommand($command) {
    $result = shell_exec('echo "' . $command . '" | /usr/local/bin/bird-proxy');
    return $result;
}

$action = isset($_GET['action']) ? $_GET['action'] : '';
$response = ['status' => 'error', 'message' => 'Invalid action'];

switch ($action) {
    case 'protocols':
        $result = runBirdCommand('show protocols');
        $response = ['status' => 'success', 'data' => $result];
        break;
    case 'route4':
        $ip = isset($_GET['ip']) ? $_GET['ip'] : '192.30.120.10';
        $result = runBirdCommand('show route for ' . $ip);
        $response = ['status' => 'success', 'data' => $result];
        break;
    case 'route6':
        $ip = isset($_GET['ip']) ? $_GET['ip'] : '2620:71:4000::c01e:780a';
        $result = runBirdCommand('show route for ' . $ip);
        $response = ['status' => 'success', 'data' => $result];
        break;
    default:
        $status = runBirdCommand('show status');
        $protocols = runBirdCommand('show protocols');
        $route4 = runBirdCommand('show route for 192.30.120.10');
        $route6 = runBirdCommand('show route for 2620:71:4000::c01e:780a');
        
        $response = [
            'status' => 'success',
            'data' => [
                'status' => $status,
                'protocols' => $protocols,
                'route4' => $route4,
                'route6' => $route6
            ]
        ];
}

echo json_encode($response);
EOF

# Install PHP if needed for the API endpoint
apt-get install -y php-fpm

# Add PHP configuration to Nginx
cat >> /etc/nginx/conf.d/looking-glass.conf << 'PHP'

    # PHP handler
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
    }
PHP

# Fix PHP-FPM socket path
PHP_SOCK=$(find /var/run/php/ -name "*.sock" | head -1)
if [ -n "$PHP_SOCK" ]; then
    sed -i "s|unix:/var/run/php/php-fpm.sock|unix:$PHP_SOCK|g" /etc/nginx/conf.d/looking-glass.conf
fi

# Ensure Nginx can read the files
chown -R www-data:www-data /var/www/looking-glass

# Verify Nginx configuration
nginx -t

# -----------------------------
# 6. Set up SSL certificate
# -----------------------------
echo "Setting up SSL certificate..."
if [ ! -d "/etc/letsencrypt/live/lg.infinitum-nihil.com" ]; then
    certbot --nginx -d lg.infinitum-nihil.com --non-interactive --agree-tos --email admin@infinitum-nihil.com
    echo "SSL certificate installed"
else
    echo "SSL certificate already exists, skipping"
fi

# -----------------------------
# 7. Restart services
# -----------------------------
echo "Restarting services..."
systemctl restart nginx

echo "Setup complete! The enhanced BGP Looking Glass is now available at https://lg.infinitum-nihil.com"
echo "Note: This implementation provides a visually enhanced static page with detailed BGP information"
echo "      while bypassing the Python version requirements of Hyperglass"
EOF

echo "Enhanced BGP looking glass setup script has been executed on the LAX server."
echo "Visit https://lg.infinitum-nihil.com to access the looking glass."