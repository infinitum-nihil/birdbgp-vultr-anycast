#!/bin/bash
# setup_simple_looking_glass.sh - Sets up a simple looking glass

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"  # Adjust as needed
PRIMARY_SERVER="lax"
PRIMARY_IP="149.248.2.74"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to set up the looking glass
setup_looking_glass() {
  echo -e "${BLUE}Setting up simple looking glass on $PRIMARY_SERVER ($PRIMARY_IP)...${NC}"
  
  ssh -i "$SSH_KEY_PATH" "root@$PRIMARY_IP" "
    # Install required packages
    apt-get update
    apt-get install -y nginx php-fpm php-cgi php-json

    # Create looking glass directory
    mkdir -p /var/www/html/looking-glass

    # Create a simple PHP script to display BGP information
    cat > /var/www/html/looking-glass/index.php << 'EOL'
<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>BGP Looking Glass</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif;
      line-height: 1.6;
      margin: 0;
      padding: 20px;
      color: #333;
      max-width: 1200px;
      margin: 0 auto;
    }
    h1, h2, h3 {
      color: #2c3e50;
    }
    pre {
      background-color: #f8f9fa;
      padding: 15px;
      border-radius: 4px;
      overflow-x: auto;
      font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
      font-size: 14px;
    }
    .container {
      margin-bottom: 30px;
    }
    form {
      margin-bottom: 20px;
    }
    input, select, button {
      padding: 8px 12px;
      margin-right: 10px;
      border: 1px solid #ddd;
      border-radius: 4px;
    }
    button {
      background-color: #4CAF50;
      color: white;
      border: none;
      cursor: pointer;
    }
    button:hover {
      background-color: #45a049;
    }
    .tab-buttons {
      display: flex;
      margin-bottom: 20px;
    }
    .tab-button {
      background-color: #f1f1f1;
      border: none;
      padding: 10px 20px;
      cursor: pointer;
      margin-right: 5px;
    }
    .tab-button.active {
      background-color: #4CAF50;
      color: white;
    }
    .tab-content {
      display: none;
    }
    .tab-content.active {
      display: block;
    }
  </style>
</head>
<body>
  <h1>BGP Looking Glass</h1>
  
  <div class=\"tab-buttons\">
    <button class=\"tab-button active\" onclick=\"openTab(event, 'protocols')\">BGP Protocols</button>
    <button class=\"tab-button\" onclick=\"openTab(event, 'routes')\">BGP Routes</button>
    <button class=\"tab-button\" onclick=\"openTab(event, 'lookup')\">Route Lookup</button>
    <button class=\"tab-button\" onclick=\"openTab(event, 'summary')\">BGP Summary</button>
  </div>
  
  <div id=\"protocols\" class=\"tab-content active\">
    <h2>BGP Protocol Status</h2>
    <pre><?php echo htmlspecialchars(shell_exec('sudo birdc show protocols all \"*bgp*\"')); ?></pre>
  </div>
  
  <div id=\"routes\" class=\"tab-content\">
    <h2>BGP Routes</h2>
    <pre><?php echo htmlspecialchars(shell_exec('sudo birdc show route where proto ~ \"bgp*\"')); ?></pre>
  </div>
  
  <div id=\"lookup\" class=\"tab-content\">
    <h2>Route Lookup</h2>
    <form method=\"get\">
      <input type=\"text\" name=\"lookup\" placeholder=\"Enter IP or prefix (e.g. 192.30.120.0/24)\" value=\"<?php echo isset($_GET['lookup']) ? htmlspecialchars($_GET['lookup']) : ''; ?>\" size=\"40\">
      <button type=\"submit\">Lookup</button>
    </form>
    <?php if (isset($_GET['lookup']) && !empty($_GET['lookup'])): ?>
      <pre><?php echo htmlspecialchars(shell_exec('sudo birdc show route for ' . escapeshellarg($_GET['lookup']) . ' all')); ?></pre>
    <?php endif; ?>
  </div>
  
  <div id=\"summary\" class=\"tab-content\">
    <h2>BGP Summary</h2>
    <pre><?php echo htmlspecialchars(shell_exec('sudo birdc show status')); ?></pre>
    <h3>System Information</h3>
    <pre><?php echo htmlspecialchars(shell_exec('uptime')); ?></pre>
    <pre><?php echo htmlspecialchars(shell_exec('free -m')); ?></pre>
  </div>
  
  <script>
    function openTab(evt, tabName) {
      var i, tabContent, tabButtons;
      
      tabContent = document.getElementsByClassName(\"tab-content\");
      for (i = 0; i < tabContent.length; i++) {
        tabContent[i].className = tabContent[i].className.replace(\" active\", \"\");
      }
      
      tabButtons = document.getElementsByClassName(\"tab-button\");
      for (i = 0; i < tabButtons.length; i++) {
        tabButtons[i].className = tabButtons[i].className.replace(\" active\", \"\");
      }
      
      document.getElementById(tabName).className += \" active\";
      evt.currentTarget.className += \" active\";
    }
    
    // Check if there's a hash in the URL and open that tab
    if (window.location.hash) {
      const tabName = window.location.hash.substring(1);
      const tabButton = document.querySelector(`.tab-button[onclick*=\"openTab(event, '${tabName}')\"]`);
      if (tabButton) {
        tabButton.click();
      }
    }
  </script>
</body>
</html>
EOL

    # Create a simple Nginx configuration
    cat > /etc/nginx/sites-available/looking-glass << 'EOL'
server {
    listen 80;
    listen [::]:80;
    server_name _;

    root /var/www/html/looking-glass;
    index index.php index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
    }
}
EOL

    # Enable the site
    ln -sf /etc/nginx/sites-available/looking-glass /etc/nginx/sites-enabled/

    # Allow www-data to run birdc commands with sudo without password
    echo 'www-data ALL=(ALL) NOPASSWD: /usr/sbin/birdc' > /etc/sudoers.d/www-data-birdc
    chmod 440 /etc/sudoers.d/www-data-birdc

    # Fix PHP socket path if needed
    PHP_SOCK=\$(find /var/run/php/ -name \"*.sock\" | head -1)
    if [ -n \"\$PHP_SOCK\" ]; then
        sed -i \"s|unix:/var/run/php/php-fpm.sock|unix:\$PHP_SOCK|\" /etc/nginx/sites-available/looking-glass
    fi

    # Set permissions
    chown -R www-data:www-data /var/www/html/looking-glass

    # Restart Nginx
    systemctl restart nginx

    echo 'Looking glass setup completed!'
    echo \"Access the looking glass at: http://$PRIMARY_IP/\"
  "
  
  echo -e "${GREEN}Looking glass setup completed!${NC}"
  echo -e "${YELLOW}Access the looking glass at: http://$PRIMARY_IP/${NC}"
}

# Main function
main() {
  echo -e "${BLUE}Starting simple looking glass setup...${NC}"
  
  # Set up the looking glass
  setup_looking_glass
  
  echo -e "${GREEN}Simple looking glass setup completed!${NC}"
}

# Run the main function
main