#!/bin/bash
# Script to automatically renew Let's Encrypt certificate
# This script will stop the container, renew the cert, and restart the container

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Exiting..."
  exit 1
fi

# Log file for renewal operations
LOG_FILE="/var/log/letsencrypt/auto-renewal.log"
mkdir -p /var/log/letsencrypt

# Log function
log_message() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
  echo "$1"
}

log_message "Starting certificate renewal process"

# Stop the container
log_message "Stopping hyperglass container..."
docker stop hyperglass

# Run certbot renewal
log_message "Renewing certificates..."
certbot renew --quiet

# Check the result
if [ $? -eq 0 ]; then
  log_message "Certificate renewal completed successfully"
else
  log_message "Certificate renewal failed"
fi

# Start the container again
log_message "Starting hyperglass container..."
docker start hyperglass

log_message "Certificate renewal process completed"
exit 0