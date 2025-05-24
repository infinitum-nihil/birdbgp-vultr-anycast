#\!/bin/bash

SERVER_IP="149.248.2.74"

echo "Fixing nginx configuration on LAX..."

ssh root@$SERVER_IP "
# Create a simple index.html that redirects to the CGI script
cat > /var/www/html/index.html << 'EOFHTML'
<\!DOCTYPE html>
<html>
<head>
    <meta http-equiv='refresh' content='0;url=/cgi-bin/lg.cgi'>
    <title>Redirecting...</title>
</head>
<body>
    <p>Redirecting to <a href='/cgi-bin/lg.cgi'>Looking Glass</a>...</p>
</body>
</html>
EOFHTML

# Fix nginx configuration
cat > /etc/nginx/sites-available/default << 'EOFNGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    index index.html;
    
    server_name _;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location /cgi-bin/ {
        gzip off;
        include fastcgi_params;
        fastcgi_pass unix:/run/fcgiwrap.socket;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOFNGINX

# Enable the site
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/

# Test and restart nginx
nginx -t && systemctl restart nginx
"

echo "The looking glass should now be accessible at http://$SERVER_IP"
