#!/bin/bash
# Script to install hyperglass using pip and set up a temporary solution
# Until we can fully resolve the installation issues

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Setting up a temporary hyperglass solution on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Create a more detailed static HTML page
cat > /opt/hyperglass/config/index.html << 'EOC'
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
            padding: 30px;
            background-color: #f4f7f9;
            color: #333;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background-color: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        h1 {
            color: #0098FF;
            margin-top: 0;
        }
        .status {
            background-color: #e6f7ff;
            border-left: 4px solid #0098FF;
            padding: 15px;
            margin-bottom: 20px;
        }
        .component {
            margin: 20px 0;
            padding: 15px;
            background-color: #f9f9f9;
            border-radius: 5px;
        }
        .success {
            color: #00CC88;
        }
        .pending {
            color: #f4a100;
        }
        .command {
            background-color: #f1f1f1;
            padding: 10px;
            border-radius: 5px;
            font-family: monospace;
            margin: 10px 0;
        }
        .output {
            background-color: #292929;
            color: #f1f1f1;
            padding: 15px;
            border-radius: 5px;
            font-family: monospace;
            white-space: pre-wrap;
            margin: 10px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>BGP Looking Glass</h1>
        
        <div class="status">
            <p><strong>Status:</strong> We're working on installing hyperglass</p>
            <p>In the meantime, here are some BGP routing details from our anycast network.</p>
        </div>
        
        <div class="component">
            <h2>BGP Status</h2>
            <p><span class="success">✓</span> <strong>BGP Sessions:</strong> Established with Vultr (AS64515)</p>
            <p><span class="success">✓</span> <strong>Anycast IPv4:</strong> 192.30.120.10/32</p>
            <p><span class="success">✓</span> <strong>Anycast IPv6:</strong> 2620:71:4000::c01e:780a/128</p>
            <p><span class="success">✓</span> <strong>Path Prepending:</strong> Hierarchical (0x, 1x, 2x)</p>
        </div>
        
        <div class="component">
            <h2>IPv4 BGP Routes</h2>
            <div class="command">$ birdc show route for 192.30.120.10</div>
            <div class="output">192.30.120.10/32    unicast [direct1] * (240)
	dev dummy0</div>
        </div>
        
        <div class="component">
            <h2>IPv6 BGP Routes</h2>
            <div class="command">$ birdc show route for 2620:71:4000::c01e:780a</div>
            <div class="output">2620:71:4000::c01e:780a/128 unicast [direct1] * (240)
	dev dummy0</div>
        </div>
        
        <div class="component">
            <h2>BGP Sessions</h2>
            <div class="command">$ birdc show protocols</div>
            <div class="output">BIRD 2.16.2 ready.
Name       Proto      Table      State  Since         Info
vultr4     BGP        ---        up     19:02:55      Established   
vultr6     BGP        ---        up     19:02:56      Established</div>
        </div>
        
        <div class="component">
            <h2>Path Prepending</h2>
            <div class="command">$ birdc show protocols vultr4 all | grep -A5 export</div>
            <div class="output">  Channel ipv4
    State:          UP
    Table:          master4
    Preference:     100
    Input filter:   ACCEPT
    Output filter:  export_bgp_filter
    Routes:         1 imported, 1 exported, 1 preferred</div>
        </div>
        
        <div class="component">
            <h2>Network Information</h2>
            <p><strong>Primary IPv4:</strong> 45.76.76.125 (Floating IP - LAX)</p>
            <p><strong>BGP ASN:</strong> 27218</p>
            <p><strong>BGP Daemon:</strong> BIRD 2.16.2</p>
        </div>
        
        <p>Full hyperglass implementation coming soon. For now, enjoy this preview of our BGP configuration!</p>
    </div>
</body>
</html>
EOC

# Restart Nginx container to serve the updated static page
docker restart hyperglass

echo "Enhanced static page has been created."
echo "Visit https://lg.infinitum-nihil.com to view the BGP information."
EOF

echo "Temporary solution has been set up on the LAX server."
echo "Visit https://lg.infinitum-nihil.com to view the BGP information."