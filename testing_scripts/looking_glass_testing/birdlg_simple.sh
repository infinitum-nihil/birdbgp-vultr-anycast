#\!/bin/bash

# Deploy a very simple looking glass using nginx and CGI
# Created: 2025-05-23

SERVER_IP="149.248.2.74"

echo "Setting up basic CGI-based looking glass on LAX..."

ssh root@$SERVER_IP "
# Install nginx and fcgiwrap
apt-get update
apt-get install -y nginx fcgiwrap

# Create a simple CGI script for the looking glass
mkdir -p /var/www/html/cgi-bin
cat > /var/www/html/cgi-bin/lg.cgi << 'EOFCGI'
#\!/bin/bash

echo 'Content-type: text/html'
echo ''

# HTML header
cat << HTML_HEADER
<\!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AS27218 Infinitum Nihil Looking Glass</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; line-height: 1.6; }
        h1 { color: #0064c1; }
        pre { background-color: #f5f5f5; padding: 15px; border-radius: 5px; overflow: auto; }
        .container { max-width: 1200px; margin: 0 auto; }
        form { margin-bottom: 20px; }
        select, input, button { padding: 8px; margin: 5px 0; }
        button { background-color: #0064c1; color: white; border: none; cursor: pointer; }
        button:hover { background-color: #004e97; }
    </style>
</head>
<body>
    <div class="container">
        <h1>AS27218 Infinitum Nihil Looking Glass</h1>
        <p>This service provides real-time visibility into our global BGP routing infrastructure.</p>
        
        <form method="GET">
            <select name="command">
                <option value="show protocols">Show Protocols</option>
                <option value="show protocols all">Show Protocols (Detailed)</option>
                <option value="show route">Show Routes</option>
                <option value="show route where protocol = bgp">Show BGP Routes</option>
                <option value="show route for">Show Route For Prefix</option>
                <option value="show route for 192.30.120.0/23">Show Route For 192.30.120.0/23</option>
                <option value="show route for 2620:71:4000::/48">Show Route For 2620:71:4000::/48</option>
                <option value="show status">Show Status</option>
                <option value="show memory">Show Memory Usage</option>
            </select>
            
            <input type="text" name="param" placeholder="Optional parameter">
            
            <button type="submit">Execute</button>
        </form>
HTML_HEADER

# Process query
COMMAND=""
PARAM=""

if [ -n "$QUERY_STRING" ]; then
    # Parse query string
    IFS='&' read -r -a pairs <<< "$QUERY_STRING"
    for pair in "${pairs[@]}"; do
        IFS='=' read -r key value <<< "$pair"
        value=$(echo "$value"  < /dev/null |  sed 's/+/ /g;s/%\([0-9A-F][0-9A-F]\)/\\\\\\x\1/g')
        value=$(echo -e "$value")
        
        if [ "$key" == "command" ]; then
            COMMAND="$value"
        elif [ "$key" == "param" ]; then
            PARAM="$value"
        fi
    done
fi

# Execute BIRD command if present
if [ -n "$COMMAND" ]; then
    echo "<h2>Command: $COMMAND $PARAM</h2>"
    echo "<pre>"
    
    # Determine which socket to use based on command
    if [[ "$COMMAND $PARAM" == *"::"* ]] || [[ "$COMMAND" == *"ipv6"* ]]; then
        # IPv6 command
        birdc -s /var/run/bird/bird6.ctl "$COMMAND $PARAM" | sed 's/</\&lt;/g' | sed 's/>/\&gt;/g'
    else
        # IPv4 command
        birdc -s /var/run/bird/bird.ctl "$COMMAND $PARAM" | sed 's/</\&lt;/g' | sed 's/>/\&gt;/g'
    fi
    
    echo "</pre>"
else
    echo "<h2>Select a command to execute</h2>"
    echo "<p>Choose a command from the dropdown menu above and click 'Execute'.</p>"
fi

# HTML footer
cat << HTML_FOOTER
    </div>
</body>
</html>
HTML_FOOTER
EOFCGI

# Make the script executable
chmod +x /var/www/html/cgi-bin/lg.cgi

# Create an index.html that redirects to the CGI script
cat > /var/www/html/index.html << 'EOFHTML'
<\!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="0; url=/cgi-bin/lg.cgi" />
    <title>Redirecting...</title>
</head>
<body>
    <p>Redirecting to <a href="/cgi-bin/lg.cgi">Looking Glass</a>...</p>
</body>
</html>
EOFHTML

# Configure nginx
cat > /etc/nginx/sites-available/looking-glass << 'EOFNGINX'
server {
    listen 80;
    server_name _;
    
    root /var/www/html;
    index index.html;
    
    location /cgi-bin/ {
        gzip off;
        fastcgi_pass unix:/var/run/fcgiwrap.socket;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOFNGINX

# Enable the site
ln -sf /etc/nginx/sites-available/looking-glass /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart fcgiwrap
systemctl restart nginx
"

echo "Basic looking glass should now be accessible at http://$SERVER_IP"
