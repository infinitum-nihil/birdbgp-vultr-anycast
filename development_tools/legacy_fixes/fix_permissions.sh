#\!/bin/bash

SERVER_IP="149.248.2.74"

echo "Fixing permissions on LAX..."

ssh root@$SERVER_IP "
# Fix script execution permissions
chmod 755 /var/www/html/cgi-bin/lg.cgi
chown www-data:www-data /var/www/html/cgi-bin/lg.cgi

# Check if the script can be executed
su - www-data -s /bin/bash -c '/var/www/html/cgi-bin/lg.cgi'

# Create a simpler direct HTML file that uses AJAX
cat > /var/www/html/index.html << 'EOFHTML'
<\!DOCTYPE html>
<html>
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>AS27218 Infinitum Nihil Looking Glass</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; line-height: 1.6; }
        h1 { color: #0064c1; }
        pre { background-color: #f5f5f5; padding: 15px; border-radius: 5px; overflow: auto; }
        .container { max-width: 1200px; margin: 0 auto; }
        form { margin-bottom: 20px; }
        select, button { padding: 8px; margin: 5px 0; }
        button { background-color: #0064c1; color: white; border: none; cursor: pointer; }
        button:hover { background-color: #004e97; }
    </style>
</head>
<body>
    <div class=\"container\">
        <h1>AS27218 Infinitum Nihil Looking Glass</h1>
        <p>This service provides real-time visibility into our global BGP routing infrastructure. Currently viewing from <strong>Los Angeles (LAX)</strong>.</p>
        
        <form id=\"commandForm\">
            <select id=\"command\">
                <option value=\"show protocols\">Show Protocols</option>
                <option value=\"show protocols all\">Show Protocols (Detailed)</option>
                <option value=\"show route\">Show Routes</option>
                <option value=\"show route where protocol = bgp\">Show BGP Routes</option>
                <option value=\"show route for 192.30.120.0/23\">Show Route For 192.30.120.0/23</option>
                <option value=\"show route for 2620:71:4000::/48\">Show Route For 2620:71:4000::/48</option>
                <option value=\"show status\">Show Status</option>
                <option value=\"show memory\">Show Memory Usage</option>
            </select>
            
            <button type=\"button\" onclick=\"executeBirdCommand()\">Execute</button>
        </form>
        
        <h2 id=\"commandTitle\">Select a command to execute</h2>
        <pre id=\"output\">Choose a command from the dropdown menu above and click 'Execute'.</pre>

        <div class=\"footer\">
            <p>AS27218 Infinitum Nihil Network</p>
            <p>IPv4: 192.30.120.0/23  < /dev/null |  IPv6: 2620:71:4000::/48</p>
        </div>
    </div>

    <script>
        function executeBirdCommand() {
            const command = document.getElementById('command').value;
            document.getElementById('commandTitle').innerText = 'Command: ' + command;
            document.getElementById('output').innerText = 'Executing command, please wait...';
            
            // Create a small server-side script to execute the command
            fetch('/execute-bird.php?command=' + encodeURIComponent(command))
                .then(response => response.text())
                .then(data => {
                    document.getElementById('output').innerText = data;
                })
                .catch(error => {
                    document.getElementById('output').innerText = 'Error executing command: ' + error;
                });
        }
    </script>
</body>
</html>
EOFHTML

# Create PHP file to execute commands
mkdir -p /var/www/html
cat > /var/www/html/execute-bird.php << 'EOFPHP'
<?php
header('Content-Type: text/plain');

// Get the command from the query string
$command = isset(\$_GET['command']) ? \$_GET['command'] : '';

// Whitelist of allowed commands for security
\$allowed_commands = [
    'show protocols',
    'show protocols all',
    'show route',
    'show route where protocol = bgp',
    'show route for 192.30.120.0/23',
    'show route for 2620:71:4000::/48',
    'show status',
    'show memory'
];

// Check if command is allowed
\$allowed = false;
foreach (\$allowed_commands as \$allowed_command) {
    if (\$command === \$allowed_command) {
        \$allowed = true;
        break;
    }
}

if (\!\$allowed) {
    echo \"Error: Command not allowed for security reasons.\";
    exit;
}

// Determine which socket to use based on command
\$socket = (strpos(\$command, '::') \!== false || strpos(\$command, 'ipv6') \!== false) 
    ? '/var/run/bird/bird6.ctl' 
    : '/var/run/bird/bird.ctl';

// Execute the command
\$output = shell_exec(\"birdc -s \$socket \$command 2>&1\");

// Output the result
echo \$output;
EOFPHP

# Install PHP-FPM for nginx
apt-get update
apt-get install -y php-fpm

# Configure nginx to use PHP
cat > /etc/nginx/sites-available/default << 'EOFNGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    index index.html index.php;
    
    server_name _;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
    }
}
EOFNGINX

# Enable the site
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/

# Test and restart services
nginx -t && systemctl restart nginx php8.1-fpm
"

echo "The PHP-based looking glass should now be accessible at http://$SERVER_IP"
