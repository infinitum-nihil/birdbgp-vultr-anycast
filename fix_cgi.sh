#\!/bin/bash

# Fix the CGI setup
# Created: 2025-05-23

SERVER_IP="149.248.2.74"

echo "Fixing CGI setup on LAX..."

ssh root@$SERVER_IP "
# Check fcgiwrap status
systemctl status fcgiwrap

# Fix permissions
chmod 755 /var/www/html/cgi-bin/lg.cgi
chown www-data:www-data /var/www/html/cgi-bin/lg.cgi

# Ensure fcgiwrap is running
systemctl restart fcgiwrap

# Check fcgiwrap socket
ls -la /var/run/fcgiwrap*

# Fix nginx configuration
cat > /etc/nginx/sites-available/looking-glass << 'EOFNGINX'
server {
    listen 80;
    server_name _;
    
    root /var/www/html;
    index index.html;
    
    location /cgi-bin/ {
        gzip off;
        include /etc/nginx/fastcgi_params;
        fastcgi_pass unix:/var/run/fcgiwrap.socket;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param QUERY_STRING \$query_string;
    }
}
EOFNGINX

# Test and restart nginx
nginx -t && systemctl restart nginx

# Check if socket exists
if [ \! -S /var/run/fcgiwrap.socket ]; then
  echo 'Socket does not exist, creating link'
  ln -s /run/fcgiwrap.socket /var/run/fcgiwrap.socket
fi

systemctl restart fcgiwrap
systemctl restart nginx
"

echo "The looking glass should now be accessible at http://$SERVER_IP"
