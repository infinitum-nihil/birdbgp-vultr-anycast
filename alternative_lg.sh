#\!/bin/bash

# Deploy an alternative looking glass solution
# Created: 2025-05-23

SERVER_IP="149.248.2.74"

echo "Setting up Alice-LG on LAX..."

# Stop existing containers
ssh root@$SERVER_IP "docker stop hyperglass redis traefik || true"
ssh root@$SERVER_IP "docker rm hyperglass redis traefik || true"
ssh root@$SERVER_IP "docker network rm hyperglass_network || true"

# Set up Alice-LG (a simpler looking glass)
ssh root@$SERVER_IP "
# Install Go for Alice-LG
apt-get update
apt-get install -y golang-go git

# Create bird-socket to netcat proxy
cat > /usr/local/bin/bird-proxy.sh << 'EOFPROXY'
#\!/bin/bash
# Simple proxy for BIRD commands
echo \"\$@\"  < /dev/null |  nc -U /var/run/bird/bird.ctl
EOFPROXY
chmod +x /usr/local/bin/bird-proxy.sh

# Clone and build Alice-LG
cd /root
git clone https://github.com/alice-lg/alice-lg.git
cd alice-lg
make

# Create Alice-LG configuration
mkdir -p /etc/alice-lg
cat > /etc/alice-lg/alice.conf << 'EOFALICE'
{
  \"server\": {
    \"listen\": \"0.0.0.0:80\"
  },
  \"ui\": {
    \"title\": \"AS27218 Infinitum Nihil Looking Glass\",
    \"disclaimer\": \"This is a BGP looking glass for AS27218 Infinitum Nihil Network.\",
    \"apple_touch_icon\": \"\",
    \"show_routes_filtered\": true,
    \"show_rpki_invalid\": true,
    \"show_neighbors_status\": true,
    \"mozilla_observatory\": {
      \"enabled\": false
    },
    \"rejections\": [
      { \"type\": \"asn\", \"values\": [] },
      { \"type\": \"prefix\", \"values\": [] },
      { \"type\": \"nexthop\", \"values\": [] }
    ]
  },
  \"asn\": {
    \"preset_options\": [],
    \"preset_values\": []
  },
  \"lookup\": {
    \"sources\": []
  },
  \"housekeeping\": {
    \"interval\": 60
  },
  \"response_cache\": {
    \"enabled\": true,
    \"max_age\": 60
  },
  \"noises\": [\"BGP.\", \"BIRD\"],
  \"neighbors_status_update_interval\": 60,
  \"neighbors_config\": {
    \"required_fields\": []
  },
  \"neighbor\": {},
  \"blackhole\": {},
  \"config_paths\": [],
  \"rs\": [
    {
      \"id\": \"lax\",
      \"name\": \"Los Angeles (LAX)\",
      \"location\": \"Los Angeles, CA, USA\",
      \"timezone\": \"America/Los_Angeles\",
      \"keep_sessions\": 500,
      \"log_rotate_limit\": 1000,
      \"bgpd\": {
        \"type\": \"bird2\",
        \"options\": {
          \"cmd\": \"/usr/local/bin/bird-proxy.sh\",
          \"enforce_json_opaque\": false
        }
      },
      \"routeservers\": [
        {
          \"id\": \"bgp4\",
          \"name\": \"IPv4\",
          \"birdc\": \"/usr/local/bin/bird-proxy.sh\",
          \"group\": \"default\",
          \"src_version\": 4
        },
        {
          \"id\": \"bgp6\",
          \"name\": \"IPv6\",
          \"birdc\": \"/usr/local/bin/bird-proxy.sh\",
          \"group\": \"default\",
          \"src_version\": 6
        }
      ]
    }
  ]
}
EOFALICE

# Create systemd service for Alice-LG
cat > /etc/systemd/system/alice-lg.service << 'EOFSERVICE'
[Unit]
Description=Alice Looking Glass
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/alice-lg
ExecStart=/root/alice-lg/bin/alice-lg -config /etc/alice-lg/alice.conf
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSERVICE

# Enable and start service
systemctl daemon-reload
systemctl enable alice-lg
systemctl restart alice-lg

# Configure firewall
ufw allow 80/tcp comment 'Allow HTTP for Looking Glass'
"

echo "Checking Alice-LG service status..."
ssh root@$SERVER_IP "systemctl status alice-lg"

echo "Alice-LG should now be accessible at http://$SERVER_IP"
