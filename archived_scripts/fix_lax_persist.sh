#!/bin/bash
# Script to create persistent configuration for LAX server
# Created by Claude

# Source .env file to get SSH key path
source "$(dirname "$0")/.env"

# LAX server IP
LAX_IP="149.248.2.74"

echo "Creating persistent configuration on LAX server ($LAX_IP)..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@$LAX_IP << 'EOF'
# Create required directories if they don't exist
mkdir -p /etc/systemd/system
mkdir -p /etc/modules-load.d

# Create a systemd service to setup the dummy interface and anycast IPs
cat > /etc/systemd/system/anycast-setup.service << 'EOT'
[Unit]
Description=Setup Anycast IP Configuration
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-anycast.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOT

# Create the setup script
cat > /usr/local/bin/setup-anycast.sh << 'EOT'
#!/bin/bash
# Load dummy module if not already loaded
modprobe dummy

# Create dummy0 interface if it doesn't exist
if ! ip link show dummy0 >/dev/null 2>&1; then
  ip link add dummy0 type dummy
  ip link set dummy0 up
fi

# Add anycast IPs to dummy0 interface
ip addr add 192.30.120.10/32 dev dummy0 2>/dev/null || true
ip -6 addr add 2620:71:4000::c01e:780a/128 dev dummy0 2>/dev/null || true

# Make sure the interface is up
ip link set dummy0 up

# Ensure proper static routes for Vultr BGP peers
# This is critical for multihop BGP to work
GATEWAY_IPV4=$(ip route | grep default | awk '{print $3}')
ip route add 169.254.169.254/32 via $GATEWAY_IPV4 2>/dev/null || true

# Update link-local address in BIRD config if needed
current_linklocal=$(ip -6 addr show dev enp1s0 | grep -i 'fe80' | awk '{print $2}' | cut -d'/' -f1)
if [ -n "$current_linklocal" ] && [ -f /etc/bird/bird.conf ]; then
  # Find any incorrect link-local address and update it
  sed -i "s|fe80:[^%]*%enp1s0|$current_linklocal%enp1s0|g" /etc/bird/bird.conf
fi

# Restart BIRD if it's already installed
if systemctl is-active --quiet bird; then
  systemctl restart bird
fi

exit 0
EOT

# Make the script executable
chmod +x /usr/local/bin/setup-anycast.sh

# Ensure dummy module is loaded at boot
echo "dummy" > /etc/modules-load.d/dummy.conf

# Enable and start the service
systemctl enable anycast-setup.service
systemctl start anycast-setup.service

# Verify dummy0 interface is up
ip link show dev dummy0

# Verify anycast IPs are configured
ip addr show dev dummy0
EOF

echo "Persistent configuration has been set up on LAX server."
echo "The dummy interface and anycast IPs will now be configured automatically at boot."
echo "You can check the status with: ssh root@$LAX_IP systemctl status anycast-setup"