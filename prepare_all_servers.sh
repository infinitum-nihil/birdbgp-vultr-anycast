#\!/bin/bash

# Create a looking glass for all servers
# Created: 2025-05-23

# Server IPs from config file
LAX_IP="149.248.2.74"
ORD_IP="66.42.113.101"
MIA_IP="149.28.108.180"
EWR_IP="66.135.18.138"

# Files to copy
scp simple-lg.php root@$LAX_IP:/var/www/html/index.php
scp simple-lg.php root@$ORD_IP:/var/www/html/index.php
scp simple-lg.php root@$MIA_IP:/var/www/html/index.php
scp simple-lg.php root@$EWR_IP:/var/www/html/index.php

# Fix permissions
for IP in $LAX_IP $ORD_IP $MIA_IP $EWR_IP; do
  echo "Setting up looking glass on $IP..."
  ssh root@$IP "
    # Install nginx and PHP
    apt-get update
    apt-get install -y nginx php-fpm
    
    # Configure nginx
    cat > /etc/nginx/sites-available/default << 'EOFNGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    index index.php index.html;
    
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

    # Make sure directories exist
    mkdir -p /var/www/html
    
    # Fix permissions
    chmod 644 /var/www/html/index.php
    chown www-data:www-data /var/www/html/index.php
    
    # Setup anycast IP
    if \! ip link show dummy0 > /dev/null 2>&1; then
      echo 'Creating dummy interface...'
      modprobe dummy
      ip link add dummy0 type dummy
      ip link set dummy0 up
    fi

    # Add anycast IPv4 address if not already assigned
    if \! ip addr show dev dummy0  < /dev/null |  grep -q '192.30.120.10'; then
      ip addr add 192.30.120.10/32 dev dummy0
      echo 'Added anycast IPv4 address 192.30.120.10 to dummy0'
    fi

    # Add anycast IPv6 address if not already assigned
    if \! ip addr show dev dummy0 | grep -q '2620:71:4000::10'; then
      ip addr add 2620:71:4000::10/128 dev dummy0
      echo 'Added anycast IPv6 address 2620:71:4000::10 to dummy0'
    fi

    # Make interface persist across reboots
    cat > /etc/systemd/network/10-dummy0.netdev << 'NETDEV'
[NetDev]
Name=dummy0
Kind=dummy
NETDEV

    cat > /etc/systemd/network/20-dummy0.network << 'NETWORK'
[Match]
Name=dummy0

[Network]
Address=192.30.120.10/32
Address=2620:71:4000::10/128
NETWORK

    # Allow web traffic
    ufw allow 80/tcp comment 'Allow HTTP'
    
    # Restart services
    systemctl restart nginx php8.1-fpm
  "
done

echo "All looking glasses should now be accessible via the anycast IP 192.30.120.10"
