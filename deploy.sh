#!/bin/bash
# Vultr BGP Anycast Deployment Script
# Automates the deployment of BGP Anycast infrastructure on Vultr
# Following Vultr documentation for floating IPs and BGP
#
# Deployment Strategy:
# - Servers deployed in configurable regions for geographic distribution
# - By default, maximized geographic placement within the Americas region (East Coast, Southeast, Midwest, West Coast)
# - Reserved IPs assigned in the same region as required by Vultr
# - Using smallest instance type (1 CPU, 1GB RAM) to minimize costs while maintaining functionality

# Function to get human-readable region name from region code
get_region_name() {
  local region_code="$1"
  local region_name=""
  
  case "$region_code" in
    "ewr")
      region_name="Piscataway/Newark"
      ;;
    "mia")
      region_name="Miami"
      ;;
    "ord")
      region_name="Chicago"
      ;;
    "lax")
      region_name="Los Angeles"
      ;;
    "sjc")
      region_name="San Jose"
      ;;
    *)
      # If unknown region code, just use the code itself
      region_name="$region_code"
      ;;
  esac
  
  echo "$region_name"
}

# Create a log file for deployment
LOG_FILE="birdbgp_deploy_$(date +%Y%m%d_%H%M%S).log"
echo "Starting deployment at $(date)" | tee "$LOG_FILE"

# Log function to write to both console and log file
log() {
  local message="$1"
  local level="${2:-INFO}"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handling function
handle_error() {
  local exit_code=$?
  local line_number=$1
  log "Error occurred at line $line_number, exit code: $exit_code" "ERROR"
  log "Deployment failed. See $LOG_FILE for details." "ERROR"
  exit $exit_code
}

# Set up error trap
trap 'handle_error $LINENO' ERR

# Enhanced error checking
set -o pipefail  # Ensure pipeline errors are caught

# Additional deployment details:
# - 3 servers for IPv4 BGP with path prepending for failover priority
# - 1 server for IPv6 BGP

# Set default configuration options
CLEANUP_RESERVED_IPS=${CLEANUP_RESERVED_IPS:-true}
IP_STACK_MODE=${IP_STACK_MODE:-dual}

# Create error and success counters for tracking deployment issues
ERROR_COUNT=0
SUCCESS_COUNT=0

# Interactive setup function for .env configuration
setup_env() {
  if [ -f ".env" ]; then
    read -p ".env file already exists. Do you want to reconfigure it? (y/n): " reconfigure
    if [[ ! $reconfigure =~ ^[Yy]$ ]]; then
      return 0
    fi
  fi

  echo "Setting up .env configuration..."
  echo "--------------------------------"
  
  # Vultr API key
  read -p "Enter your Vultr API key: " vultr_api_key
  
  # BGP configuration
  read -p "Enter your AS number (e.g., 65000): " as_number
  read -p "Enter your IPv4 BGP range (e.g., 192.0.2.0/24): " ipv4_range
  read -p "Enter your IPv6 BGP range (e.g., 2001:db8::/48): " ipv6_range
  read -p "Enter your Vultr BGP password: " bgp_password
  
  # SSH key path
  read -p "Enter the absolute path to your SSH private key: " ssh_key_path
  
  # Deployment options
  read -p "Deploy with cloud-init? (y/n, default: y): " use_cloud_init
  use_cloud_init=${use_cloud_init:-y}
  if [[ $use_cloud_init =~ ^[Yy]$ ]]; then
    use_cloud_init_value="true"
  else
    use_cloud_init_value="false"
  fi
  
  read -p "Clean up unused reserved IPs before deployment? (y/n, default: y): " cleanup_ips
  cleanup_ips=${cleanup_ips:-y}
  if [[ $cleanup_ips =~ ^[Yy]$ ]]; then
    cleanup_ips_value="true"
  else
    cleanup_ips_value="false"
  fi
  
  echo "Select deployment mode:"
  echo "1) Dual-stack (IPv4 + IPv6) [default]"
  echo "2) IPv4 only"
  echo "3) IPv6 only"
  read -p "Enter your choice (1-3): " stack_choice
  
  case "${stack_choice:-1}" in
    1) ip_stack_mode="dual" ;;
    2) ip_stack_mode="ipv4" ;;
    3) ip_stack_mode="ipv6" ;;
    *) ip_stack_mode="dual" ;;  # Default to dual for invalid input
  esac
  
  # Write to .env file
  cat > .env << EOF
# Environment variables for birdbgp deployment
# Generated on $(date)

# Vultr API credentials
VULTR_API_KEY=${vultr_api_key}
VULTR_API_ENDPOINT=https://api.vultr.com/v2/

# BGP configuration
OUR_AS=${as_number}
OUR_IPV4_BGP_RANGE=${ipv4_range}
OUR_IPV6_BGP_RANGE=${ipv6_range}
VULTR_BGP_PASSWORD=${bgp_password}

# SSH key configuration
SSH_KEY_PATH=${ssh_key_path}

# Deployment options
USE_CLOUD_INIT=${use_cloud_init_value}
CLEANUP_RESERVED_IPS=${cleanup_ips_value}
IP_STACK_MODE=${ip_stack_mode}
EOF

  echo ".env file created successfully!"
  
  # Export the variables for the current session
  export VULTR_API_KEY=${vultr_api_key}
  export VULTR_API_ENDPOINT="https://api.vultr.com/v2/"
  export OUR_AS=${as_number}
  export OUR_IPV4_BGP_RANGE=${ipv4_range}
  export OUR_IPV6_BGP_RANGE=${ipv6_range}
  export VULTR_BGP_PASSWORD=${bgp_password}
  export SSH_KEY_PATH=${ssh_key_path}
  export USE_CLOUD_INIT=${use_cloud_init_value}
  export CLEANUP_RESERVED_IPS=${cleanup_ips_value}
  export IP_STACK_MODE=${ip_stack_mode}
  
  return 0
}

# Source or setup environment variables
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "Error: .env file not found."
  echo "Would you like to set up your configuration now?"
  read -p "Set up configuration? (y/n): " setup_now
  if [[ $setup_now =~ ^[Yy]$ ]]; then
    setup_env
  else
    echo "Please create a .env file based on .env.sample before running this script."
    exit 1
  fi
fi

# Check required variables
if [ -z "$VULTR_API_KEY" ] || [ -z "$OUR_AS" ] || [ -z "$OUR_IPV4_BGP_RANGE" ] || [ -z "$OUR_IPV6_BGP_RANGE" ] || [ -z "$VULTR_BGP_PASSWORD" ]; then
  echo "Error: Required environment variables are missing!"
  exit 1
fi

# Set up SSH options
SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

# Check for optional SSH key path
if [ -z "$SSH_KEY_PATH" ]; then
  echo "Note: SSH_KEY_PATH environment variable not set."
  echo "If Vultr doesn't have your SSH key, you might not be able to SSH into the servers."
  echo "Consider adding SSH_KEY_PATH to your .env file."
else
  # Read the public key from the file
  if [ -f "${SSH_KEY_PATH}.pub" ]; then
    NT_SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")
    echo "Using SSH public key from ${SSH_KEY_PATH}.pub"
    SSH_OPTIONS="$SSH_OPTIONS -i $SSH_KEY_PATH"
    echo "Using SSH key file for authentication: $SSH_KEY_PATH"
  else
    echo "Warning: SSH public key file ${SSH_KEY_PATH}.pub not found."
    unset NT_SSH_PUBLIC_KEY
  fi
fi

# Set regions and plans - can be overridden in .env file
# Default regions in Americas region but users can change to their preferred regions
IPV4_REGION_PRIMARY=${IPV4_REGION_PRIMARY:-"ewr"} # Default: Newark
IPV4_REGION_SECONDARY=${IPV4_REGION_SECONDARY:-"mia"} # Default: Miami
IPV4_REGION_TERTIARY=${IPV4_REGION_TERTIARY:-"ord"} # Default: Chicago
IPV4_REGIONS=("$IPV4_REGION_PRIMARY" "$IPV4_REGION_SECONDARY" "$IPV4_REGION_TERTIARY")
IPV6_REGION=${IPV6_REGION:-"lax"} # Default: Los Angeles

# Region to BGP community mapping
# These values are used for Vultr BGP communities based on datacenter location
declare -A REGION_TO_COMMUNITY=(
  ["ewr"]="11"  # Piscataway, NJ (closest to Newark)
  ["mia"]="12"  # Miami
  ["ord"]="13"  # Chicago
  ["sjc"]="18"  # San Jose
  ["lax"]="17"  # Los Angeles
)

# Region to country code mapping (for large communities)
# Format for large communities: 20473:0:3RRRCCC1PP where RRR=region, CCC=country, PP=location
# 019 for Americas, 840 for US
declare -A REGION_TO_LARGE_COMMUNITY=(
  ["lax"]="301984017"  # Los Angeles
  ["ewr"]="301984011"  # Piscataway, NJ (closest to Newark)
  ["mia"]="301984012"  # Miami
  ["ord"]="301984013"  # Chicago
  ["sjc"]="301984018"  # San Jose
)
PLAN="vc2-1c-1gb"  # Smallest plan (1 CPU, 1GB RAM) - sufficient for BGP/BIRD2
# Operating system selection
# To use a different Ubuntu version, uncomment the desired OS_ID and comment the others
OS_ID=1743 # Ubuntu 22.04 LTS x64
# OS_ID=387  # Ubuntu 20.04 LTS x64
# OS_ID=270  # Ubuntu 18.04 LTS x64

# Load cloud-init setting from .env with default to "true"
USE_CLOUD_INIT=${USE_CLOUD_INIT:-true}

# Function to generate cloud-init configuration
generate_cloud_init_config() {
  local ipv6_enabled=$1
  
  # If cloud-init is not enabled, return the simple bash script
  if [ "$USE_CLOUD_INIT" != "true" ]; then
    echo "IyEvYmluL2Jhc2gKYXB0LWdldCB1cGRhdGUgJiYgYXB0LWdldCBpbnN0YWxsIC15IGJpcmQyCg=="
    return
  fi
  
  # IPv4 BGP instance cloud-init
  if [ "$ipv6_enabled" = "false" ]; then
    cat << 'CLOUDINIT' | base64 -w 0
#cloud-config
package_update: true
package_upgrade: true

apt:
  sources:
    bird2:
      source: "ppa:cz.nic-labs/bird"

packages:
  - bird2
  - fail2ban
  - iptables-persistent
  - ipset
  - unattended-upgrades
  - curl
  - gnupg2
  - build-essential
  - net-tools
  - logrotate

write_files:
  - path: /etc/bird/bird.conf
    owner: bird:bird
    permissions: '0644'
    content: |
      # This config will be replaced during deployment
      log syslog all;
      router id 127.0.0.1;
      protocol device { scan time 10; }
      
  - path: /etc/logrotate.d/bird2
    owner: root:root
    permissions: '0644'
    content: |
      /var/log/bird*.log {
        daily
        missingok
        rotate 14
        compress
        delaycompress
        notifempty
        create 640 root adm
        sharedscripts
        postrotate
          systemctl reload bird > /dev/null 2>&1 || true
        endscript
      }
      
  - path: /etc/sysctl.d/99-bgp-security.conf
    owner: root:root
    permissions: '0644'
    content: |
      # BGP security settings
      net.ipv4.conf.all.rp_filter=0
      net.ipv4.conf.default.rp_filter=0
      net.ipv4.conf.lo.rp_filter=0
      net.ipv4.conf.all.accept_redirects=0
      net.ipv4.conf.default.accept_redirects=0
      net.ipv4.conf.all.secure_redirects=0
      net.ipv4.conf.default.secure_redirects=0
      net.ipv4.conf.all.send_redirects=0
      net.ipv4.conf.default.send_redirects=0
      net.ipv4.conf.all.accept_source_route=0
      net.ipv4.conf.default.accept_source_route=0
      net.ipv4.tcp_syncookies=1
      net.ipv4.icmp_echo_ignore_broadcasts=1
      net.ipv4.icmp_ignore_bogus_error_responses=1

  - path: /etc/apt/apt.conf.d/50unattended-upgrades
    owner: root:root
    permissions: '0644'
    content: |
      Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESM:${distro_codename}";
      };
      Unattended-Upgrade::Package-Blacklist {
      };
      Unattended-Upgrade::Automatic-Reboot "true";
      Unattended-Upgrade::Automatic-Reboot-Time "02:00";
      Unattended-Upgrade::Remove-Unused-Dependencies "true";
      Unattended-Upgrade::SyslogEnable "true";

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root:root
    permissions: '0644'
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

  - path: /etc/fail2ban/jail.local
    owner: root:root
    permissions: '0644'
    content: |
      [DEFAULT]
      bantime = 86400
      findtime = 3600
      maxretry = 5
      banaction = iptables-multiport

      [sshd]
      enabled = true
      port = ssh
      filter = sshd
      logpath = /var/log/auth.log
      maxretry = 3

  - path: /etc/ssh/sshd_config.d/10-security.conf
    owner: root:root
    permissions: '0644'
    content: |
      # SSH hardening
      PermitRootLogin prohibit-password
      PasswordAuthentication no
      X11Forwarding no
      MaxAuthTries 3
      LoginGraceTime 20
      AllowAgentForwarding no
      AllowTcpForwarding no
      PermitEmptyPasswords no

runcmd:
  # Configure iptables-persistent quietly
  - 'export DEBIAN_FRONTEND=noninteractive'
  - 'echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections'
  - 'echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections'
  
  # Create dummy interface for BGP announcements
  - 'ip link add dummy1 type dummy || true'
  - 'ip link set dummy1 up'
  
  # Install CrowdSec with no interactive prompts
  - 'curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash'
  - 'UCF_FORCE_CONFFOLD=1 apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" crowdsec'
  - 'UCF_FORCE_CONFFOLD=1 apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" crowdsec-firewall-bouncer-iptables'
  
  # Enable and start services
  - 'systemctl enable --now bird'
  - 'systemctl enable --now fail2ban'
  - 'systemctl enable --now unattended-upgrades'
  - 'systemctl enable --now iptables-persistent'
  - 'systemctl enable --now crowdsec'
  - 'systemctl enable --now crowdsec-firewall-bouncer'
  
  # Setup basic firewall rules
  - 'iptables -F'
  - 'iptables -A INPUT -i lo -j ACCEPT'
  - 'iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT'
  - 'iptables -A INPUT -p tcp --dport 22 -j ACCEPT'
  - 'iptables -A INPUT -p tcp --dport 179 -j ACCEPT'
  - 'iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT'
  # RPKI validator IPs - restrict port 323 to only these IPs
  - 'iptables -A INPUT -p tcp --dport 323 -s 192.5.4.1 -j ACCEPT'     # ARIN
  - 'iptables -A INPUT -p tcp --dport 323 -s 193.0.24.0/24 -j ACCEPT' # RIPE
  - 'iptables -A INPUT -p tcp --dport 323 -s 1.1.1.1 -j ACCEPT'       # Cloudflare
  - 'iptables -A INPUT -p tcp --dport 323 -s 1.0.0.1 -j ACCEPT'       # Cloudflare
  - 'iptables -A INPUT -j DROP'
  - 'iptables-save > /etc/iptables/rules.v4'
  
  # Configure CrowdSec with default collections (with yes to all prompts)
  - 'yes | cscli collections install crowdsecurity/linux'
  - 'yes | cscli collections install crowdsecurity/sshd'
  - 'yes | cscli collections install crowdsecurity/iptables'
  - 'systemctl restart crowdsec'
  
  # Apply sysctl changes
  - 'sysctl -p /etc/sysctl.d/99-bgp-security.conf'
CLOUDINIT
  # IPv6 BGP instance cloud-init
  else
    cat << 'CLOUDINIT6' | base64 -w 0
#cloud-config
package_update: true
package_upgrade: true

apt:
  sources:
    bird2:
      source: "ppa:cz.nic-labs/bird"

packages:
  - bird2
  - fail2ban
  - iptables-persistent
  - ipset
  - unattended-upgrades
  - curl
  - gnupg2
  - build-essential
  - net-tools
  - logrotate

write_files:
  - path: /etc/bird/bird.conf
    owner: bird:bird
    permissions: '0644'
    content: |
      # This config will be replaced during deployment
      log syslog all;
      router id 127.0.0.1;
      protocol device { scan time 10; }
      
  - path: /etc/logrotate.d/bird2
    owner: root:root
    permissions: '0644'
    content: |
      /var/log/bird*.log {
        daily
        missingok
        rotate 14
        compress
        delaycompress
        notifempty
        create 640 root adm
        sharedscripts
        postrotate
          systemctl reload bird > /dev/null 2>&1 || true
        endscript
      }
      
  - path: /etc/sysctl.d/99-bgp-security.conf
    owner: root:root
    permissions: '0644'
    content: |
      # BGP security settings
      net.ipv4.conf.all.rp_filter=0
      net.ipv4.conf.default.rp_filter=0
      net.ipv4.conf.lo.rp_filter=0
      net.ipv4.conf.all.accept_redirects=0
      net.ipv4.conf.default.accept_redirects=0
      net.ipv4.conf.all.secure_redirects=0
      net.ipv4.conf.default.secure_redirects=0
      net.ipv4.conf.all.send_redirects=0
      net.ipv4.conf.default.send_redirects=0
      net.ipv4.conf.all.accept_source_route=0
      net.ipv4.conf.default.accept_source_route=0
      net.ipv4.tcp_syncookies=1
      net.ipv4.icmp_echo_ignore_broadcasts=1
      net.ipv4.icmp_ignore_bogus_error_responses=1
      
      # IPv6 specific settings
      net.ipv6.conf.all.accept_redirects=0
      net.ipv6.conf.default.accept_redirects=0
      net.ipv6.conf.all.accept_source_route=0
      net.ipv6.conf.default.accept_source_route=0
      net.ipv6.conf.all.forwarding=0
      net.ipv6.conf.default.forwarding=0

  - path: /etc/apt/apt.conf.d/50unattended-upgrades
    owner: root:root
    permissions: '0644'
    content: |
      Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESM:${distro_codename}";
      };
      Unattended-Upgrade::Package-Blacklist {
      };
      Unattended-Upgrade::Automatic-Reboot "true";
      Unattended-Upgrade::Automatic-Reboot-Time "02:00";
      Unattended-Upgrade::Remove-Unused-Dependencies "true";
      Unattended-Upgrade::SyslogEnable "true";

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root:root
    permissions: '0644'
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

  - path: /etc/fail2ban/jail.local
    owner: root:root
    permissions: '0644'
    content: |
      [DEFAULT]
      bantime = 86400
      findtime = 3600
      maxretry = 5
      banaction = iptables-multiport

      [sshd]
      enabled = true
      port = ssh
      filter = sshd
      logpath = /var/log/auth.log
      maxretry = 3

  - path: /etc/ssh/sshd_config.d/10-security.conf
    owner: root:root
    permissions: '0644'
    content: |
      # SSH hardening
      PermitRootLogin prohibit-password
      PasswordAuthentication no
      X11Forwarding no
      MaxAuthTries 3
      LoginGraceTime 20
      AllowAgentForwarding no
      AllowTcpForwarding no
      PermitEmptyPasswords no

runcmd:
  # Configure iptables-persistent quietly
  - 'export DEBIAN_FRONTEND=noninteractive'
  - 'echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections'
  - 'echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections'
  
  # Create dummy interface for BGP announcements
  - 'ip link add dummy1 type dummy || true'
  - 'ip link set dummy1 up'
  
  # Install CrowdSec with no interactive prompts
  - 'curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash'
  - 'UCF_FORCE_CONFFOLD=1 apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" crowdsec'
  - 'UCF_FORCE_CONFFOLD=1 apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" crowdsec-firewall-bouncer-iptables'
  
  # Enable and start services
  - 'systemctl enable --now bird'
  - 'systemctl enable --now fail2ban'
  - 'systemctl enable --now unattended-upgrades'
  - 'systemctl enable --now iptables-persistent'
  - 'systemctl enable --now crowdsec'
  - 'systemctl enable --now crowdsec-firewall-bouncer'
  
  # Setup basic firewall rules for IPv4
  - 'iptables -F'
  - 'iptables -A INPUT -i lo -j ACCEPT'
  - 'iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT'
  - 'iptables -A INPUT -p tcp --dport 22 -j ACCEPT'
  - 'iptables -A INPUT -p tcp --dport 179 -j ACCEPT'
  - 'iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT'
  # RPKI validator IPs - restrict port 323 to only these IPs
  - 'iptables -A INPUT -p tcp --dport 323 -s 192.5.4.1 -j ACCEPT'     # ARIN
  - 'iptables -A INPUT -p tcp --dport 323 -s 193.0.24.0/24 -j ACCEPT' # RIPE
  - 'iptables -A INPUT -p tcp --dport 323 -s 1.1.1.1 -j ACCEPT'       # Cloudflare
  - 'iptables -A INPUT -p tcp --dport 323 -s 1.0.0.1 -j ACCEPT'       # Cloudflare
  - 'iptables -A INPUT -j DROP'
  - 'iptables-save > /etc/iptables/rules.v4'
  
  # Setup basic firewall rules for IPv6
  - 'ip6tables -F'
  - 'ip6tables -A INPUT -i lo -j ACCEPT'
  - 'ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT'
  - 'ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT'
  - 'ip6tables -A INPUT -p tcp --dport 179 -j ACCEPT'
  - 'ip6tables -A INPUT -p ipv6-icmp -j ACCEPT'
  # RPKI validator IPv6 addresses - restrict port 323 to only these IPs
  - 'ip6tables -A INPUT -p tcp --dport 323 -s 2620:4f:8000::/48 -j ACCEPT'  # ARIN
  - 'ip6tables -A INPUT -p tcp --dport 323 -s 2001:67c:e0::/48 -j ACCEPT'   # RIPE
  - 'ip6tables -A INPUT -p tcp --dport 323 -s 2606:4700:4700::1111 -j ACCEPT' # Cloudflare
  - 'ip6tables -A INPUT -p tcp --dport 323 -s 2606:4700:4700::1001 -j ACCEPT' # Cloudflare
  - 'ip6tables -A INPUT -j DROP'
  - 'ip6tables-save > /etc/iptables/rules.v6'
  
  # Configure CrowdSec with default collections (with yes to all prompts)
  - 'yes | cscli collections install crowdsecurity/linux'
  - 'yes | cscli collections install crowdsecurity/sshd'
  - 'yes | cscli collections install crowdsecurity/iptables'
  - 'systemctl restart crowdsec'
  
  # Apply sysctl changes
  - 'sysctl -p /etc/sysctl.d/99-bgp-security.conf'
CLOUDINIT6
  fi
}

# Function to create SSH key in Vultr account
create_ssh_key_in_vultr() {
  # Check if we have a path to the SSH public key file
  if [ -z "$SSH_KEY_PATH" ]; then
    echo "No SSH key path available. Cannot create SSH key in Vultr."
    return 1
  fi
  
  # Make sure we have the public key content
  if [ -z "$NT_SSH_PUBLIC_KEY" ]; then
    if [ -f "${SSH_KEY_PATH}.pub" ]; then
      NT_SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")
      echo "Read SSH public key from ${SSH_KEY_PATH}.pub"
    else
      echo "No SSH public key found at ${SSH_KEY_PATH}.pub"
      return 1
    fi
  fi

  local key_name="birdbgp-$(date +%Y%m%d-%H%M%S)"
  echo "Creating SSH key in Vultr with name: $key_name"
  
  # Create the SSH key via Vultr API
  ssh_key_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}ssh-keys" \
    -H "Authorization: Bearer ${VULTR_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "{
      \"name\": \"$key_name\",
      \"ssh_key\": \"$NT_SSH_PUBLIC_KEY\"
    }")
  
  # Extract the SSH key ID from the response
  created_ssh_key_id=$(echo $ssh_key_response | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ -z "$created_ssh_key_id" ]; then
    echo "Failed to create SSH key in Vultr. Response: $ssh_key_response"
    return 1
  fi
  
  echo "Successfully created SSH key in Vultr with ID: $created_ssh_key_id"
  echo "$created_ssh_key_id" > "vultr_ssh_key_id.txt"
  return 0
}

# Function to create a Vultr instance
create_instance() {
  local region=$1
  local label=$2
  local priority=$3
  local ipv6_enabled=$4 # true/false

  echo "Creating $label instance in $region..."
  
  # Get SSH key ID for our deployment
  ssh_key_id=""
  
  # First check if we already created a key for this deployment
  if [ -f "vultr_ssh_key_id.txt" ]; then
    ssh_key_id=$(cat vultr_ssh_key_id.txt)
    echo "Using previously created SSH key ID: $ssh_key_id"
  else
    # Check if SSH key exists in Vultr account
    ssh_keys=$(curl -s -X GET "${VULTR_API_ENDPOINT}ssh-keys" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    # First try to find the exact key we know works (by fingerprint)
    # The fingerprint 8xsygNZkKcXV3ncVtjxkopcl7AVdc0aBhvC1WYeJVXM was observed as working
    echo "Looking for SSH key with fingerprint matching the working key..."
    ssh_key_id=$(echo $ssh_keys | grep -i "SHA256:8xsygNZkKcXV3ncVtjxkopcl7AVdc0aBhvC1WYeJVXM" | grep -o '"id":"[^"]*' | cut -d'"' -f4 | head -1)
    
    # If the specific key isn't found, look for any key with nt@infinitum-nihil.com in name
    if [ -z "$ssh_key_id" ]; then
      ssh_key_id=$(echo $ssh_keys | grep -o '"id":"[^"]*","name":"[^"]*nt@infinitum-nihil.com[^"]*' | cut -d'"' -f4 | head -1)
    fi
    
    # If still no key, try to create one
    if [ -z "$ssh_key_id" ] && [ ! -z "$NT_SSH_PUBLIC_KEY" ]; then
      echo "No matching SSH key found. Attempting to create a new SSH key in Vultr..."
      if create_ssh_key_in_vultr; then
        ssh_key_id=$(cat vultr_ssh_key_id.txt)
      fi
    fi
  fi
  
  # Check if we have a valid SSH key ID
  if [ -z "$ssh_key_id" ]; then
    echo "WARNING: No valid SSH key ID available. You won't be able to directly SSH into the VMs."
    echo "Proceeding with deployment using default SSH key management..."
    
    # Create instance without SSH key
    response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{
        \"region\": \"$region\",
        \"plan\": \"$PLAN\",
        \"label\": \"$label\",
        \"os_id\": $OS_ID,
        \"enable_ipv6\": $ipv6_enabled,
        \"tags\": [\"bgp\", \"priority-$priority\"],
        \"user_data\": \"$(generate_cloud_init_config $ipv6_enabled)\"
      }")
  else
    echo "Using SSH key ID: $ssh_key_id for instance deployment"
    
    # Create instance with SSH key
    response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{
        \"region\": \"$region\",
        \"plan\": \"$PLAN\",
        \"label\": \"$label\",
        \"os_id\": $OS_ID,
        \"enable_ipv6\": $ipv6_enabled,
        \"tags\": [\"bgp\", \"priority-$priority\"],
        \"sshkey_id\": [\"$ssh_key_id\"],
        \"user_data\": \"$(generate_cloud_init_config $ipv6_enabled)\"
      }")
  fi
  
  # Extract instance ID
  instance_id=$(echo $response | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ -z "$instance_id" ]; then
    echo "Failed to create instance! Response: $response"
    return 1
  fi
  
  echo "Instance created with ID: $instance_id"
  echo "$instance_id" > "${label}_id.txt"
  
  # Wait for instance to be ready
  echo "Waiting for instance to be ready..."
  while true; do
    status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    if [ "$status" == "active" ]; then
      echo "Instance is ready!"
      break
    fi
    
    echo "Instance status: $status. Waiting..."
    sleep 10
  done
  
  # Get instance IP addresses
  instance_info=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  ipv4=$(echo $instance_info | grep -o '"main_ip":"[^"]*' | cut -d'"' -f4)
  echo "Instance IPv4: $ipv4"
  echo "$ipv4" > "${label}_ipv4.txt"
  
  if [ "$ipv6_enabled" = "true" ]; then
    ipv6=$(echo $instance_info | grep -o '"v6_main_ip":"[^"]*' | cut -d'"' -f4)
    echo "Instance IPv6: $ipv6"
    echo "$ipv6" > "${label}_ipv6.txt"
  fi
  
  return 0
}

# Function to check for existing reserved IPs
check_existing_reserved_ip() {
  local region=$1
  local ip_type=$2  # v4 or v6
  local label="floating-${ip_type/v/ip}-$region"
  
  echo "Checking for existing reserved IP with label: $label in region $region..."
  
  existing_ips=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  # Debug: show response format
  echo "Reserved IPs API response format sample (truncated):"
  echo "$existing_ips" | head -n 30 | tail -n 10
  
  # Check if response is valid JSON
  if ! echo "$existing_ips" | grep -q "\"reserved_ips\""; then
    echo "Error: Invalid response from reserved-ips API"
    echo "Response: $existing_ips"
    return 1
  fi
  
  # Use jq-like parsing with grep and sed to extract matching reserved IPs
  echo "Searching for reserved IPs matching label '$label' and region '$region'..."
  
  # Extract the reserved_ips array
  reserved_ips_array=$(echo "$existing_ips" | sed -n 's/.*"reserved_ips":\[\([^]]*\)\].*/\1/p')
  
  # Process each reserved IP object
  if echo "$reserved_ips_array" | grep -q "$label"; then
    echo "Found at least one reserved IP with matching label pattern"
    
    # Extract the ID and subnet from the response
    local existing_id=""
    local existing_ip=""
    
    # Extract all reserved IP objects and process them
    echo "$existing_ips" | grep -o '{[^{]*"id":"[^"]*"[^}]*"label":"[^"]*"[^}]*}' | while read -r ip_obj; do
      # Check if this object has our label and region
      if echo "$ip_obj" | grep -q "\"label\":\"$label\"" && echo "$ip_obj" | grep -q "\"region\":\"$region\""; then
        existing_id=$(echo "$ip_obj" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
        existing_ip=$(echo "$ip_obj" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
        
        echo "Found exact match! Reserved IP: $existing_ip (ID: $existing_id)"
        
        # Save the found IP and ID to files
        echo "$existing_id" > "floating_${ip_type/v/ip}_${region}_id.txt"
        echo "$existing_ip" > "floating_${ip_type/v/ip}_${region}.txt"
        
        # Return success
        return 0
      fi
    done
  fi
  
  echo "No matching reserved IP found, will create a new one"
  return 1
}

# Function to create a floating IP
create_floating_ip() {
  local instance_id=$1
  local region=$2
  local ip_type=$3  # ipv4 or ipv6
  
  echo "Creating floating $ip_type in region $region..."
  
  # Convert ip_type to correct format for API (v4 or v6)
  local api_ip_type="v4"
  if [ "$ip_type" = "ipv6" ]; then
    api_ip_type="v6"
  fi
  
  # Check if we already have a reserved IP for this region/type
  if check_existing_reserved_ip "$region" "$api_ip_type"; then
    floating_ip_id=$(cat "floating_${ip_type}_${region}_id.txt")
    floating_ip=$(cat "floating_${ip_type}_${region}.txt")
    
    echo "Using existing floating IP: $floating_ip (ID: $floating_ip_id)"
  else
    # Create a new reserved IP
    echo "Creating new reserved IP for $ip_type in region $region..."
    response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{
        \"region\": \"$region\",
        \"ip_type\": \"$api_ip_type\",
        \"label\": \"floating-ip${ip_type:1}-$region\"
      }")
    
    echo "Reserved IP creation response: $response"
    
    # Handle various response formats
    if [[ "$response" == *"error"* ]]; then
      echo "Error creating reserved IP: $response"
      return 1
    fi
    
    # Extract floating IP details - handle different response formats
    floating_ip_id=""
    floating_ip=""
    
    # Format 1: Nested in reserved_ip object
    if [[ "$response" == *'"reserved_ip":'* ]]; then
      echo "Parsing response format 1 (nested reserved_ip object)"
      # Extract the nested object
      reserved_ip_obj=$(echo "$response" | grep -o '"reserved_ip":{[^}]*}' | sed 's/"reserved_ip"://g')
      
      # Extract fields from the object
      floating_ip_id=$(echo "$reserved_ip_obj" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      floating_ip=$(echo "$reserved_ip_obj" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      
      echo "Extracted from nested object - ID: $floating_ip_id, IP: $floating_ip"
    fi
    
    # Format 2: Direct in response
    if [ -z "$floating_ip_id" ] || [ -z "$floating_ip" ]; then
      echo "Trying parse format 2 (direct response)"
      floating_ip_id=$(echo "$response" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      floating_ip=$(echo "$response" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      
      echo "Extracted direct - ID: $floating_ip_id, IP: $floating_ip"
    fi
    
    # Format 3: Alternative field names
    if [ -z "$floating_ip" ]; then
      echo "Trying parse format 3 (alternative field names)"
      floating_ip=$(echo "$response" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
      echo "Extracted alternative - IP: $floating_ip"
    fi
    
    # Final validation
    if [ -z "$floating_ip_id" ]; then
      echo "Failed to extract reserved IP ID from response!"
      echo "Raw response: $response"
      return 1
    fi
    
    if [ -z "$floating_ip" ]; then
      echo "Failed to extract reserved IP address from response!"
      echo "Raw response: $response"
      return 1
    fi
    
    # Save the IDs and IPs - create all possible formats for maximum compatibility
    log "Creating floating IP files in multiple formats for compatibility" "INFO"
    
    # Format with ip and vX (e.g., ipv4)
    echo "$floating_ip_id" > "floating-ip${ip_type}-${region}_id.txt"
    echo "$floating_ip" > "floating-ip${ip_type}-${region}.txt"
    echo "$floating_ip_id" > "floating_ip${ip_type}_${region}_id.txt"
    echo "$floating_ip" > "floating_ip${ip_type}_${region}.txt"
    
    # Format with just number (e.g., ip4)
    echo "$floating_ip_id" > "floating-ip${ip_type:1}-${region}_id.txt"
    echo "$floating_ip" > "floating-ip${ip_type:1}-${region}.txt"
    echo "$floating_ip_id" > "floating_ip${ip_type:1}_${region}_id.txt"
    echo "$floating_ip" > "floating_ip${ip_type:1}_${region}.txt"
    
    echo "Successfully created new floating IP: $floating_ip (ID: $floating_ip_id)"
  fi
  
  # Attach floating IP to instance
  echo "Attaching floating $ip_type to instance $instance_id..."
  echo "Floating IP ID: $floating_ip_id, Instance ID: $instance_id"
  
  # Check if the instance is fully provisioned and running
  echo "Verifying instance is ready for IP attachment..."
  instance_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
  
  echo "Instance status: $instance_status"
  
  # Wait for the instance to be fully ready (ok status)
  max_attempts=10
  attempt=1
  while [ "$instance_status" != "ok" ] && [ $attempt -le $max_attempts ]; do
    echo "Instance not ready (status: $instance_status). Waiting 10 seconds (attempt $attempt/$max_attempts)..."
    sleep 10
    instance_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    echo "Updated instance status: $instance_status"
    attempt=$((attempt + 1))
  done
  
  # Give additional time for services to stabilize
  echo "Waiting 10 seconds before attempting to attach reserved IP..."
  sleep 10
  
  # First check if the IP is already attached
  echo "Checking if IP is already attached to any instance..."
  current_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  current_instance=$(echo "$current_status" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4)
  
  if [ ! -z "$current_instance" ] && [ "$current_instance" = "$instance_id" ]; then
    echo "Floating IP is already attached to the correct instance $instance_id"
    return 0
  elif [ ! -z "$current_instance" ]; then
    echo "Warning: Floating IP is attached to a different instance: $current_instance"
    echo "Will attempt to detach first..."
    
    # Detach from current instance
    detach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id/detach" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    echo "Detach response: $detach_response"
    
    # Wait for detachment to complete
    echo "Waiting 15 seconds for detachment to complete..."
    sleep 15
  fi
  
  # First attempt - use the reserved-ips endpoint
  echo "Attempting to attach IP using reserved-ips/$floating_ip_id/attach endpoint..."
  attach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id/attach" \
    -H "Authorization: Bearer ${VULTR_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "{
      \"instance_id\": \"$instance_id\"
    }")
  
  echo "Attachment response: $attach_response"
  
  # Check if attachment was successful
  if [[ "$attach_response" == *"error"* ]]; then
    echo "Warning: Error attaching floating IP. Response: $attach_response"
    echo "Will try alternate API endpoint..."
    
    # Wait before trying alternate endpoint
    sleep 10
    
    # Try the alternate endpoint format
    echo "Attempting to attach IP using instances/$instance_id/reserved-ips endpoint..."
    alt_attach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances/$instance_id/reserved-ips" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{
        \"reserved_ip\": \"$floating_ip_id\"
      }")
      
    echo "Alternate attachment response: $alt_attach_response"
    
    if [[ "$alt_attach_response" == *"error"* ]]; then
      echo "Error with alternate endpoint too. Response: $alt_attach_response"
      echo "Checking current attachment status to see if it succeeded despite errors..."
      
      # Check if the IP is already attached (sometimes API returns error but it works)
      ip_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
      
      echo "Reserved IP status: $ip_status"
      
      attached_instance=$(echo "$ip_status" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4)
      if [ "$attached_instance" = "$instance_id" ]; then
        echo "IP appears to be correctly attached to instance $instance_id despite API errors!"
      else
        echo "IP attachment failed. You may need to manually attach the floating IP in the Vultr console."
        # Continue anyway, as this won't prevent the rest of the deployment
      fi
    else
      echo "Floating IP attached using alternate endpoint."
    fi
  else
    echo "Floating IP attached successfully."
  fi
  
  # Final verification
  echo "Performing final verification of IP attachment..."
  sleep 5
  final_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_ip_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  final_instance=$(echo "$final_status" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4)
  
  if [ "$final_instance" = "$instance_id" ]; then
    echo "Verified: Floating IP $floating_ip is correctly attached to instance $instance_id"
    
    # According to Vultr, server must be restarted before the additional IP can be used
    echo "Restarting instance for the reserved IP to take effect (Vultr requirement)..."
    restart_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances/$instance_id/reboot" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    echo "Restart response: $restart_response"
    
    # Wait for the restart to complete
    echo "Waiting 60 seconds for instance restart to complete..."
    sleep 60
    
    # Check instance status after restart
    instance_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    echo "Instance status after restart: $instance_status"
    
    # Wait for the instance to be fully ready again if needed
    max_attempts=10
    attempt=1
    while [ "$instance_status" != "ok" ] && [ $attempt -le $max_attempts ]; do
      echo "Instance not ready after restart (status: $instance_status). Waiting 10 seconds (attempt $attempt/$max_attempts)..."
      sleep 10
      instance_status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$instance_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
      echo "Updated instance status: $instance_status"
      attempt=$((attempt + 1))
    done
    
    echo "IP attachment and instance restart completed successfully."
    return 0
  else
    echo "Warning: Final verification shows floating IP is not attached to expected instance."
    echo "Current status: $final_status"
    echo "Expected instance: $instance_id, Current instance: $final_instance"
    echo "Continuing deployment, but manual verification may be needed."
  fi
  
  return 0
}

# Function to generate BIRD configuration for IPv4 servers
generate_ipv4_bird_config() {
  local server_type=$1
  local ipv4=$2
  local prepend_count=$3
  local config_file="${server_type}_bird.conf"
  
  echo "Generating IPv4 BIRD configuration for $server_type server..."
  
  # Start with basic configuration
  cat > "$config_file" << EOL
# Global configuration
router id $ipv4;
log syslog all;
debug protocols all;

# RPKI Configuration
roa table rpki_table;

# Use local Routinator as primary RPKI validator
# This is configured with ARIN TAL as first priority
protocol rpki rpki_routinator {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "localhost" port 8323;  # Routinator local RTR server
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Use ARIN's validator as first external fallback 
# ARIN operates an RTR service available publicly
protocol rpki rpki_arin {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.arin.net" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Fallback to RIPE NCC's validator as second external fallback
# Using RIPE RPKI Validator 3 (rpki-validator3.ripe.net) which is the current version
protocol rpki rpki_ripe {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rpki-validator3.ripe.net" port 8323;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Add Cloudflare's RPKI validator as final fallback
protocol rpki rpki_cloudflare {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.cloudflare.com" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Enhanced RPKI validation function with route coloring (communities)
function rpki_check() {
  # Store original validation state for community tagging
  case roa_check(rpki_table, net, bgp_path.last) {
    ROA_VALID: {
      # Add community to mark route as RPKI valid
      bgp_community.add((${OUR_AS}, 1001));
      print "RPKI: Valid route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_UNKNOWN: {
      # Add community to mark route as RPKI unknown
      bgp_community.add((${OUR_AS}, 1002));
      print "RPKI: Unknown route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_INVALID: {
      # Add community to mark route as RPKI invalid before rejecting
      bgp_community.add((${OUR_AS}, 1000));
      print "RPKI: Invalid route: ", net, " ASN: ", bgp_path.last;
      reject;
    }
  }
}

# Device protocol to detect interfaces
protocol device {
  scan time 5;
}

# Direct protocol to use with dummy interface
protocol direct {
  interface "dummy*";
  ipv4;
}

# Define networks to announce
protocol static {
  ipv4 {
    export all;
  };
  route ${OUR_IPV4_BGP_RANGE} blackhole;
}

# BGP configuration for Vultr
protocol bgp vultr {
  description "vultr";
  local as ${OUR_AS};
  source address $ipv4;
  ipv4 {
    import where rpki_check();
EOL

  # Export filter with Vultr communities for path control
  if [ $prepend_count -gt 0 ]; then
    cat >> "$config_file" << EOL
    export filter {
      # Only export routes from direct and static protocols
      if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
        # Add Vultr BGP communities based on prepend count
EOL
    
    # Use Vultr-specific communities instead of manual path prepending
    if [ $prepend_count -eq 1 ]; then
      echo "        bgp_community.add((20473,6001));" >> "$config_file"
    elif [ $prepend_count -eq 2 ]; then
      echo "        bgp_community.add((20473,6002));" >> "$config_file"
    elif [ $prepend_count -eq 3 ]; then
      echo "        bgp_community.add((20473,6003));" >> "$config_file"
    fi
    
    # Add location-based communities based on server region
    region=${IPV4_REGIONS[$((prepend_count-1))]}
    community_code=${REGION_TO_COMMUNITY[$region]:-"0"}
    region_name=$(get_region_name "$region")
    
    if [[ "$community_code" != "0" ]]; then
      echo "        # Add $region_name location community" >> "$config_file"
      echo "        bgp_community.add((20473,$community_code));" >> "$config_file"
    fi
    
    cat >> "$config_file" << EOL
        accept;
      } else {
        reject;
      }
    };
EOL
  else
    cat >> "$config_file" << EOL
    export filter {
      # Only export routes from direct and static protocols
      if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
        # Add appropriate Vultr BGP communities for primary server
        # Add origin customer community
        bgp_community.add((20473,4000));
        
        # Add location community for this server
EOL
    
    # Add location-based communities based on server region
    region=${IPV4_REGIONS[0]}
    community_code=${REGION_TO_COMMUNITY[$region]:-"0"}
    region_name=$(get_region_name "$region")
    
    if [[ "$community_code" != "0" ]]; then
      echo "        # Add $region_name location community" >> "$config_file"
      echo "        bgp_community.add((20473,$community_code));" >> "$config_file"
    fi
    
    cat >> "$config_file" << EOL
        accept;
      } else {
        reject;
      }
    };
EOL
  fi

  # Continue with the rest of the configuration
  cat >> "$config_file" << EOL
  };
  graceful restart on;
  multihop 2;
  neighbor 169.254.169.254 as 64515;
  password "${VULTR_BGP_PASSWORD}";
}
EOL

  echo "IPv4 BIRD configuration generated at $config_file"
}

# Function to generate BIRD configuration for IPv6 server
generate_ipv6_bird_config() {
  local server_type=$1
  local ipv4=$2
  local ipv6=$3
  local config_file="${server_type}_bird.conf"
  
  # Calculate the link-local address from the IPv6 address
  # Extract second half of IPv6 address (the part containing ff:fe)
  local ipv6_suffix=$(echo $ipv6 | sed -E 's/.*:([0-9a-f:]+)/\1/')
  local link_local="fe80::$ipv6_suffix"
  
  echo "Generating IPv6 BIRD configuration for $server_type server..."
  echo "IPv6 address: $ipv6"
  echo "Link-local address: $link_local"
  
  # Create IPv6 configuration
  cat > "$config_file" << EOL
# Global configuration
router id $ipv4;
log syslog all;
debug protocols all;

# RPKI Configuration
roa table rpki_table;

# Use local Routinator as primary RPKI validator
# This is configured with ARIN TAL as first priority
protocol rpki rpki_routinator {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "localhost" port 8323;  # Routinator local RTR server
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Use ARIN's validator as first external fallback 
# ARIN operates an RTR service available publicly
protocol rpki rpki_arin {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.arin.net" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Fallback to RIPE NCC's validator as second external fallback
# Using RIPE RPKI Validator 3 (rpki-validator3.ripe.net) which is the current version
protocol rpki rpki_ripe {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rpki-validator3.ripe.net" port 8323;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Add Cloudflare's RPKI validator as final fallback
protocol rpki rpki_cloudflare {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.cloudflare.com" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Enhanced RPKI validation function with route coloring (communities)
function rpki_check() {
  # Store original validation state for community tagging
  case roa_check(rpki_table, net, bgp_path.last) {
    ROA_VALID: {
      # Add community to mark route as RPKI valid
      bgp_community.add((${OUR_AS}, 1001));
      print "RPKI: Valid route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_UNKNOWN: {
      # Add community to mark route as RPKI unknown
      bgp_community.add((${OUR_AS}, 1002));
      print "RPKI: Unknown route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_INVALID: {
      # Add community to mark route as RPKI invalid before rejecting
      bgp_community.add((${OUR_AS}, 1000));
      print "RPKI: Invalid route: ", net, " ASN: ", bgp_path.last;
      reject;
    }
  }
}

# Device protocol to detect interfaces
protocol device {
  scan time 5;
}

# Direct protocol to use with dummy interface
protocol direct {
  interface "dummy*";
  ipv6;
}

# Define networks to announce
protocol static {
  ipv6 {
    export all;
  };
  route ${OUR_IPV6_BGP_RANGE} blackhole;
}

# Required static route to Vultr's BGP server
protocol static STATIC6 {
  ipv6;
  route 2001:19f0:ffff::1/128 via $link_local%eth0;
}

# IPv6 BGP configuration
protocol bgp vultr6 {
  description "vultr";
  local $ipv6 as ${OUR_AS};
  neighbor 2001:19f0:ffff::1 as 64515;
  multihop 2;
  password "${VULTR_BGP_PASSWORD}";
  
  ipv6 {
    import where rpki_check();
    export filter {
      if source ~ [ RTS_DEVICE ] then {
        # Add Vultr BGP communities for IPv6 routing
        
        # Add origin customer community
        bgp_community.add((20473,4000));
        
        # Add location community for this server
        region="${IPV6_REGION}"
        community_code=${REGION_TO_COMMUNITY[$region]:-"0"}
        large_community=${REGION_TO_LARGE_COMMUNITY[$region]:-"0"}
        region_name=$(get_region_name "$region")
        
        if [[ "$community_code" != "0" ]]; then
          # Add location community
          echo "        # Add $region_name location community" >> "$config_file"
          echo "        bgp_community.add((20473,$community_code));" >> "$config_file"
        fi
        
        if [[ "$large_community" != "0" ]]; then
          # Use large community format for IPv6 location
          # Format: 20473:0:3RRRCCC1PP where RRR=region, CCC=country, PP=location
          echo "        # Use large community format for IPv6 location" >> "$config_file"
          echo "        bgp_large_community.add((20473,0,$large_community));" >> "$config_file"
        fi
        
        accept;
      } else {
        reject;
      }
    };
  };
}
EOL

  echo "IPv6 BIRD configuration generated at $config_file"
}

# Function to deploy IPv4 BIRD configuration to a server
deploy_ipv4_bird_config() {
  local server_type=$1
  local ipv4=$2
  local config_file="${server_type}_bird.conf"
  local floating_ip=$3
  
  # Validate input parameters
  if [ -z "$ipv4" ]; then
    log "Error: No IP address provided for $server_type server. Deployment cannot continue." "ERROR"
    return 1
  fi
  
  # Check if config file exists
  if [ ! -f "$config_file" ]; then
    log "Error: Configuration file $config_file not found. Deployment cannot continue." "ERROR"
    return 1
  fi
  
  log "Deploying IPv4 BIRD configuration to $server_type server ($ipv4)..." "INFO"
  
  # Wait for SSH to be available
  log "Waiting for SSH to be available..." "INFO"
  while ! ssh $SSH_OPTIONS root@$ipv4 echo "SSH connection successful"; do
    log "Retrying SSH connection..." "INFO"
    sleep 10
  done
  
  # Define the log function and fix packages in the SSH session
  ssh $SSH_OPTIONS root@$ipv4 << 'FIXPKG'
# Define log function for remote server
log() {
  local message="$1"
  local level="${2:-INFO}"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message"
}

# Fix any interrupted package installations first
log "Fixing package database before installing RPKI tools..." "INFO"
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a || log "Failed to fix package database, continuing anyway" "WARN"
apt-get install -f -y || log "Failed to fix broken packages, continuing anyway" "WARN"
FIXPKG

  # Now install RPKI tools and Routinator
  ssh $SSH_OPTIONS root@$ipv4 << EOF
    # Define log function for consistent output
    log() {
      local message="\$1"
      local level="\${2:-INFO}"
      local timestamp=\$(date +"%Y-%m-%d %H:%M:%S")
      echo "[\$timestamp] [\$level] \$message"
    }
    
    log "Installing RPKI tools and Routinator..." "INFO"
    apt-get update
    
    # Try to install the RPKI tools
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y rtrlib-tools || log "Failed to install rtrlib-tools - may not be available in this Ubuntu version" "WARN"
    apt-get install -y bird2-rpki-client || log "Failed to install bird2-rpki-client - may not be available in this Ubuntu version" "WARN"
    
    # Install Rust and build Routinator from source with ASPA support
    apt-get install -y curl gnupg build-essential
    
    # Install Rust
    echo "Installing Rust toolchain for building Routinator with ASPA support..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    . "$HOME/.cargo/env"
    
    # Build Routinator with ASPA feature flag
    echo "Building Routinator from source with ASPA support..."
    cargo install --locked --features aspa routinator
    
    # Create symlinks to make routinator easily accessible
    ln -sf "$HOME/.cargo/bin/routinator" /usr/local/bin/routinator

    # Create enhanced Routinator configuration
    mkdir -p /etc/routinator
    cat > /etc/routinator/routinator.conf << 'RPKICONF'
# Routinator configuration file
repository-dir = "/var/lib/routinator/rpki-cache"
rtr-listen = ["127.0.0.1:8323", "[::1]:8323"]
refresh = 300
retry = 300
expire = 7200
history-size = 10
tal-dir = "/var/lib/routinator/tals"
log-level = "info"
validation-threads = 4

# Enable HTTP server for metrics and status page
http-listen = ["127.0.0.1:8080"]
# Enable ASPA validation - requires Routinator to be built with ASPA support
enable-aspa = true
# Enable other extensions when available
enable-bgpsec = true

# SLURM (Simplified Local Internet Number Resource Management) support
# Allows for local exceptions to RPKI data
slurm = "/etc/routinator/slurm.json"
RPKICONF

    # Create a basic SLURM file for local exceptions
    cat > /etc/routinator/slurm.json << 'SLURM'
{
  "slurmVersion": 1,
  "validationOutputFilters": {
    "prefixFilters": [],
    "bgpsecFilters": []
  },
  "locallyAddedAssertions": {
    "prefixAssertions": [],
    "bgpsecAssertions": []
  }
}
SLURM

    # Create permissions for Routinator
    # First check if routinator user exists, if not create it
    if ! id routinator &>/dev/null; then
      log "Creating routinator user and group..." "INFO"
      useradd -r -d /var/lib/routinator -s /bin/false routinator || log "Failed to create routinator user, using root instead" "WARN"
    fi
    
    # Create directories with proper permissions
    mkdir -p /etc/routinator
    mkdir -p /var/lib/routinator/tals
    
    # Try to set permissions, but continue if it fails
    chown -R routinator:routinator /etc/routinator 2>/dev/null || log "Failed to set permissions on /etc/routinator, using current user" "WARN"
    
    # Download ARIN TAL directly from the source
    log "Downloading ARIN TAL directly from ARIN..." "INFO"
    mkdir -p /var/lib/routinator/tals
    if curl -s --retry 3 --retry-delay 2 https://www.arin.net/resources/manage/rpki/arin-rfc7730.tal > /var/lib/routinator/tals/arin.tal; then
      log "Successfully downloaded ARIN TAL" "INFO"
    else
      log "Failed to download ARIN TAL, will try alternate URL" "WARN"
      # Try alternate URL as fallback
      if curl -s --retry 3 --retry-delay 2 https://rpki.arin.net/tal/arin-rfc7730.tal > /var/lib/routinator/tals/arin.tal; then
        log "Successfully downloaded ARIN TAL from alternate URL" "INFO"
      else
        log "All ARIN TAL download attempts failed. RPKI validation may not work correctly." "ERROR"
        # Create an empty TAL file so Routinator can still start
        echo "# Failed to download ARIN TAL, please add manually" > /var/lib/routinator/tals/arin.tal
      fi
    fi
    
    # Set permissions on routinator directories
    chown -R routinator:routinator /var/lib/routinator 2>/dev/null || log "Failed to set permissions on /var/lib/routinator, using current user" "WARN"
    
    # Initialize Routinator - won't prompt for ARIN RPA as we provided the TAL directly
    routinator init
    
    # Create a complete systemd service file for Routinator with ASPA support
    cat > /etc/systemd/system/routinator.service << 'SYSTEMD'
[Unit]
Description=Routinator RPKI Validator with ASPA support
After=network.target

[Service]
Type=simple
User=routinator
Group=routinator
ExecStart=/usr/local/bin/routinator server --enable-aspa --config /etc/routinator/routinator.conf
Restart=on-failure
RestartSec=5
TimeoutStopSec=60

# Resource limits
MemoryHigh=512M
MemoryMax=1G
TasksMax=100

# Security hardening
ProtectSystem=full
PrivateTmp=true
ProtectHome=true
ProtectControlGroups=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SYSTEMD

    # Create routinator user if it doesn't exist
    if ! id -u routinator > /dev/null 2>&1; then
        useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/routinator --comment "Routinator RPKI Validator" routinator
    fi

    # Set proper permissions
    mkdir -p /var/lib/routinator
    chown -R routinator:routinator /var/lib/routinator
    chown -R routinator:routinator /etc/routinator

    # Reload systemd and start Routinator
    systemctl daemon-reload
    systemctl enable --now routinator
    
    # Wait for Routinator to complete initial sync
    echo "Waiting for Routinator to sync (30 seconds)..."
    sleep 30
EOF
  
  # Copy BIRD configuration
  scp $SSH_OPTIONS "$config_file" root@$ipv4:/etc/bird/bird.conf
  
  # Define the log function within the SSH session
  ssh $SSH_OPTIONS root@$ipv4 << 'SETUPLOG'
# Define log function for remote server
log() {
  local message="$1"
  local level="${2:-INFO}"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message"
}

# Fix any interrupted package installations first
log "Checking for and fixing interrupted package installations..." "INFO"
dpkg --configure -a || log "Failed to fix package database, some installations may fail" "WARN"

# Continue with configuration
SETUPLOG

  # Now proceed with the actual configuration
  ssh $SSH_OPTIONS root@$ipv4 << EOF
    # Create dummy interface
    log "Creating dummy interface for BGP announcements..." "INFO"
    ip link add dummy1 type dummy || log "Dummy interface already exists, continuing..." "WARN"
    ip link set dummy1 up
    
    # Configure IP routes
    # Extract the network part without the CIDR suffix, then append .1
    ip_network=$(echo ${OUR_IPV4_BGP_RANGE} | cut -d'/' -f1)
    if [ -z "$ip_network" ]; then
      log "Failed to extract network address from ${OUR_IPV4_BGP_RANGE}" "ERROR"
      log "Using fallback network address of 192.0.2.0" "WARN"
      ip_network="192.0.2.0"
    fi
    
    log "Setting up dummy interface with IP: ${ip_network}.1/32" "INFO"
    ip addr add ${ip_network}.1/32 dev dummy1 || log "Failed to add IP to dummy interface, continuing..." "WARN"
    ip route add local ${OUR_IPV4_BGP_RANGE} dev lo
    
    # If floating IP is provided, configure it
    if [ ! -z "$floating_ip" ]; then
      echo "Configuring floating IP: $floating_ip"
      ip addr add $floating_ip/32 dev lo
    fi
    
    # ===== SECURITY SETUP =====
    log "Configuring security measures..." "INFO"
    
    # Ensure we have all necessary packages before continuing
    apt-get update
    
    # Try to fix any broken packages
    apt-get install -f -y || log "Failed to fix broken packages" "WARN"
    
    # Add SSH key for nt@infinitum-nihil.com if provided
    if [ ! -z "$NT_SSH_PUBLIC_KEY" ]; then
      echo "Adding SSH public key for nt@infinitum-nihil.com..."
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh
      echo "$NT_SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      echo "SSH key added successfully."
    fi
    
    # Install dependencies 
    apt-get update
    
    # Fix any broken packages first
    apt-get install -f -y
    
    # Pre-set answers for iptables-persistent to avoid interactive prompts
    export DEBIAN_FRONTEND=noninteractive
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    
    # Install each package separately with error handling
    log "Installing iptables-persistent..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" iptables-persistent || log "Failed to install iptables-persistent" "ERROR"
    
    log "Installing fail2ban..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" fail2ban || log "Failed to install fail2ban" "ERROR"
    
    log "Installing ipset..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" ipset || log "Failed to install ipset" "ERROR"
    
    log "Installing unattended-upgrades..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" unattended-upgrades || log "Failed to install unattended-upgrades" "ERROR"
    
    log "Installing logrotate..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" logrotate || log "Failed to install logrotate" "ERROR"
    
    # Configure unattended upgrades for security patches
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'APTCONF'
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APTCONF

    # Enable unattended upgrades
    echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    
    # Install and configure CrowdSec
    echo "Installing CrowdSec..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    apt-get install -y crowdsec
    
    # Configure CrowdSec with BGP-specific collections
    cscli collections install crowdsecurity/linux
    cscli collections install crowdsecurity/sshd
    
    # Add BGP/BIRD specific config for CrowdSec
    cat > /etc/crowdsec/acquis.d/bird.yaml << 'CROWDYAML'
filenames:
  - /var/log/syslog
labels:
  type: syslog
---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
CROWDYAML
    
    # Configure CrowdSec firewall bouncer
    apt-get install -y crowdsec-firewall-bouncer-iptables
    systemctl enable crowdsec-firewall-bouncer --now
    systemctl restart crowdsec
    
    # Setup base iptables rules
    echo "Configuring iptables firewall rules..."
    
    # Create ipset for allowed IPs
    ipset create bgp-allowed-ips hash:ip -exist
    ipset add bgp-allowed-ips 169.254.169.254 # Vultr BGP server
    
    # Flush existing rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    
    # Set default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    
    # Allow SSH (rate limited)
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
    
    # Allow BGP from Vultr
    iptables -A INPUT -p tcp --dport 179 -m set --match-set bgp-allowed-ips src -j ACCEPT
    
    # Allow RPKI validators (RTR protocol) - restrict to specific trusted IPs
    iptables -A INPUT -p tcp --dport 323 -s 192.5.4.1 -j ACCEPT       # ARIN
    iptables -A INPUT -p tcp --dport 323 -s 193.0.24.0/24 -j ACCEPT   # RIPE
    iptables -A INPUT -p tcp --dport 323 -s 1.1.1.1 -j ACCEPT         # Cloudflare
    iptables -A INPUT -p tcp --dport 323 -s 1.0.0.1 -j ACCEPT         # Cloudflare
    
    # Allow all ICMP for ping/traceroute functionality
    iptables -A INPUT -p icmp -j ACCEPT
    
    # DNS resolver will be local - no need to open port 53
    
    # Log denied packets
    iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables denied: " --log-level 7
    
    # Save iptables rules
    iptables-save > /etc/iptables/rules.v4
    
    # Configure sysctl for security
    cat > /etc/sysctl.d/99-security.conf << 'SYSCTL'
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Increase system file descriptor limit
fs.file-max = 65535
SYSCTL
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-security.conf
    
    # Secure SSH access
    cat > /etc/ssh/sshd_config.d/secure_ssh.conf << 'SSHCONF'
PermitRootLogin prohibit-password
PasswordAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 20
MaxSessions 2
SSHCONF
    
    # Restart SSH service
    systemctl restart sshd
    
    # Configure logrotate for BIRD logs
    log "Configuring logrotate for BIRD and system logs..." "INFO"
    cat > /etc/logrotate.d/bird2 << 'LOGROTATECFG'
/var/log/bird*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        systemctl reload bird > /dev/null 2>&1 || true
    endscript
}
LOGROTATECFG

    # Ensure system logs are also properly rotated
    cat > /etc/logrotate.d/syslog-custom << 'SYSLOGROTATE'
/var/log/syslog
/var/log/kern.log
/var/log/auth.log
/var/log/mail.log
/var/log/cron.log
/var/log/daemon.log
/var/log/messages
{
    rotate 14
    daily
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
SYSLOGROTATE

    # Make sure permissions are correct
    chmod 644 /etc/logrotate.d/bird2
    chmod 644 /etc/logrotate.d/syslog-custom
    
    echo "Security measures configured successfully."
    # ===== END SECURITY SETUP =====
    
    # Enable and start BIRD
    systemctl enable bird
    systemctl start bird
    
    # Verify BGP sessions
    echo "Checking BGP status:"
    birdc show proto all vultr
    
    # Check RPKI status
    echo "Checking RPKI status:"
    sleep 30  # Give RPKI time to connect
    echo "Routinator status:"
    birdc show protocols rpki_routinator
    echo "ARIN validator status:" 
    birdc show protocols rpki_arin
    echo "RIPE validator status:"
    birdc show protocols rpki_ripe
    echo "Cloudflare validator status:"
    birdc show protocols rpki_cloudflare
    
    # Check Routinator service
    echo "Routinator service status:"
    systemctl status routinator
    
    # Check security services
    echo "CrowdSec status:"
    systemctl status crowdsec
    echo "Fail2ban status:"
    systemctl status fail2ban
EOF
  
  echo "IPv4 BIRD configuration deployed to $server_type server"
}

# Function to deploy IPv6 BIRD configuration to a server
deploy_ipv6_bird_config() {
  local server_type=$1
  local ipv4=$2
  local config_file="${server_type}_bird.conf"
  local floating_ipv6=$3
  
  # Validate input parameters
  if [ -z "$ipv4" ]; then
    log "Error: No IPv4 address provided for $server_type server. Deployment cannot continue." "ERROR"
    return 1
  fi
  
  # Check if config file exists
  if [ ! -f "$config_file" ]; then
    log "Error: Configuration file $config_file not found. Deployment cannot continue." "ERROR"
    return 1
  fi
  
  log "Deploying IPv6 BIRD configuration to $server_type server ($ipv4)..." "INFO"
  
  # Wait for SSH to be available
  log "Waiting for SSH to be available..." "INFO"
  while ! ssh $SSH_OPTIONS root@$ipv4 echo "SSH connection successful"; do
    log "Retrying SSH connection..." "INFO"
    sleep 10
  done
  
  # Define the log function and fix packages in the SSH session
  ssh $SSH_OPTIONS root@$ipv4 << 'FIXPKG'
# Define log function for remote server
log() {
  local message="$1"
  local level="${2:-INFO}"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message"
}

# Fix any interrupted package installations first
log "Fixing package database before installing RPKI tools..." "INFO"
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a || log "Failed to fix package database, continuing anyway" "WARN"
apt-get install -f -y || log "Failed to fix broken packages, continuing anyway" "WARN"
FIXPKG

  # Now install RPKI tools and Routinator
  ssh $SSH_OPTIONS root@$ipv4 << EOF
    # Define log function for consistent output
    log() {
      local message="\$1"
      local level="\${2:-INFO}"
      local timestamp=\$(date +"%Y-%m-%d %H:%M:%S")
      echo "[\$timestamp] [\$level] \$message"
    }
    
    log "Installing RPKI tools and Routinator for IPv6..." "INFO"
    apt-get update
    
    # Try to install the RPKI tools
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y rtrlib-tools || log "Failed to install rtrlib-tools - may not be available in this Ubuntu version" "WARN"
    apt-get install -y bird2-rpki-client || log "Failed to install bird2-rpki-client - may not be available in this Ubuntu version" "WARN"
    
    # Install Rust and build Routinator from source with ASPA support
    apt-get install -y curl gnupg build-essential
    
    # Install Rust
    echo "Installing Rust toolchain for building Routinator with ASPA support..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    . "$HOME/.cargo/env"
    
    # Build Routinator with ASPA feature flag
    echo "Building Routinator from source with ASPA support..."
    cargo install --locked --features aspa routinator
    
    # Create symlinks to make routinator easily accessible
    ln -sf "$HOME/.cargo/bin/routinator" /usr/local/bin/routinator

    # Create enhanced Routinator configuration
    mkdir -p /etc/routinator
    cat > /etc/routinator/routinator.conf << 'RPKICONF'
# Routinator configuration file
repository-dir = "/var/lib/routinator/rpki-cache"
rtr-listen = ["127.0.0.1:8323", "[::1]:8323"]
refresh = 300
retry = 300
expire = 7200
history-size = 10
tal-dir = "/var/lib/routinator/tals"
log-level = "info"
validation-threads = 4

# Enable HTTP server for metrics and status page
http-listen = ["127.0.0.1:8080"]
# Enable ASPA validation - requires Routinator to be built with ASPA support
enable-aspa = true
# Enable other extensions when available
enable-bgpsec = true

# SLURM (Simplified Local Internet Number Resource Management) support
# Allows for local exceptions to RPKI data
slurm = "/etc/routinator/slurm.json"
RPKICONF

    # Create a basic SLURM file for local exceptions
    cat > /etc/routinator/slurm.json << 'SLURM'
{
  "slurmVersion": 1,
  "validationOutputFilters": {
    "prefixFilters": [],
    "bgpsecFilters": []
  },
  "locallyAddedAssertions": {
    "prefixAssertions": [],
    "bgpsecAssertions": []
  }
}
SLURM

    # Create permissions for Routinator
    # First check if routinator user exists, if not create it
    if ! id routinator &>/dev/null; then
      log "Creating routinator user and group..." "INFO"
      useradd -r -d /var/lib/routinator -s /bin/false routinator || log "Failed to create routinator user, using root instead" "WARN"
    fi
    
    # Create directories with proper permissions
    mkdir -p /etc/routinator
    mkdir -p /var/lib/routinator/tals
    
    # Try to set permissions, but continue if it fails
    chown -R routinator:routinator /etc/routinator 2>/dev/null || log "Failed to set permissions on /etc/routinator, using current user" "WARN"
    
    # Download ARIN TAL directly from the source
    log "Downloading ARIN TAL directly from ARIN..." "INFO"
    mkdir -p /var/lib/routinator/tals
    if curl -s --retry 3 --retry-delay 2 https://www.arin.net/resources/manage/rpki/arin-rfc7730.tal > /var/lib/routinator/tals/arin.tal; then
      log "Successfully downloaded ARIN TAL" "INFO"
    else
      log "Failed to download ARIN TAL, will try alternate URL" "WARN"
      # Try alternate URL as fallback
      if curl -s --retry 3 --retry-delay 2 https://rpki.arin.net/tal/arin-rfc7730.tal > /var/lib/routinator/tals/arin.tal; then
        log "Successfully downloaded ARIN TAL from alternate URL" "INFO"
      else
        log "All ARIN TAL download attempts failed. RPKI validation may not work correctly." "ERROR"
        # Create an empty TAL file so Routinator can still start
        echo "# Failed to download ARIN TAL, please add manually" > /var/lib/routinator/tals/arin.tal
      fi
    fi
    
    # Set permissions on routinator directories
    chown -R routinator:routinator /var/lib/routinator 2>/dev/null || log "Failed to set permissions on /var/lib/routinator, using current user" "WARN"
    
    # Initialize Routinator - won't prompt for ARIN RPA as we provided the TAL directly
    routinator init
    
    # Create a complete systemd service file for Routinator with ASPA support
    cat > /etc/systemd/system/routinator.service << 'SYSTEMD'
[Unit]
Description=Routinator RPKI Validator with ASPA support
After=network.target

[Service]
Type=simple
User=routinator
Group=routinator
ExecStart=/usr/local/bin/routinator server --enable-aspa --config /etc/routinator/routinator.conf
Restart=on-failure
RestartSec=5
TimeoutStopSec=60

# Resource limits
MemoryHigh=512M
MemoryMax=1G
TasksMax=100

# Security hardening
ProtectSystem=full
PrivateTmp=true
ProtectHome=true
ProtectControlGroups=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SYSTEMD

    # Create routinator user if it doesn't exist
    if ! id -u routinator > /dev/null 2>&1; then
        useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/routinator --comment "Routinator RPKI Validator" routinator
    fi

    # Set proper permissions
    mkdir -p /var/lib/routinator
    chown -R routinator:routinator /var/lib/routinator
    chown -R routinator:routinator /etc/routinator

    # Reload systemd and start Routinator
    systemctl daemon-reload
    systemctl enable --now routinator
    
    # Wait for Routinator to complete initial sync
    echo "Waiting for Routinator to sync (30 seconds)..."
    sleep 30
EOF
  
  # Copy BIRD configuration
  scp $SSH_OPTIONS "$config_file" root@$ipv4:/etc/bird/bird.conf
  
  # Calculate the link-local address from the IPv6
  local ipv6_suffix=$(echo $ipv6 | sed -E 's/.*:([0-9a-f:]+)/\1/')
  local link_local="fe80::$ipv6_suffix"
  
  # Configure network, security, and start BIRD
  ssh $SSH_OPTIONS root@$ipv4 << EOF
    # Create dummy interface if not exists
    echo "Creating dummy interface..."
    ip link add dummy1 type dummy || true
    ip link set dummy1 up
    
    # Configure IPv6 routes
    ip -6 addr add ${OUR_IPV6_BGP_RANGE%%/*}::1/128 dev dummy1
    ip -6 route add local ${OUR_IPV6_BGP_RANGE} dev lo
    
    # Add static route to Vultr's BGP server via link-local
    echo "Adding static route to Vultr's BGP server..."
    ip -6 route add 2001:19f0:ffff::1/128 via $link_local dev eth0 src $ipv6
    
    # If floating IPv6 is provided, configure it
    if [ ! -z "$floating_ipv6" ]; then
      echo "Configuring floating IPv6: $floating_ipv6"
      ip -6 addr add $floating_ipv6/128 dev lo
    fi
    
    # ===== SECURITY SETUP =====
    log "Configuring security measures..." "INFO"
    
    # Ensure we have all necessary packages before continuing
    apt-get update
    
    # Try to fix any broken packages
    apt-get install -f -y || log "Failed to fix broken packages" "WARN"
    
    # Add SSH key for nt@infinitum-nihil.com if provided
    if [ ! -z "$NT_SSH_PUBLIC_KEY" ]; then
      echo "Adding SSH public key for nt@infinitum-nihil.com..."
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh
      echo "$NT_SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      echo "SSH key added successfully."
    fi
    
    # Install dependencies 
    apt-get update
    
    # Fix any broken packages first
    apt-get install -f -y
    
    # Pre-set answers for iptables-persistent to avoid interactive prompts
    export DEBIAN_FRONTEND=noninteractive
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    
    # Install each package separately with error handling
    log "Installing iptables-persistent..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" iptables-persistent || log "Failed to install iptables-persistent" "ERROR"
    
    log "Installing fail2ban..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" fail2ban || log "Failed to install fail2ban" "ERROR"
    
    log "Installing ipset..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" ipset || log "Failed to install ipset" "ERROR"
    
    log "Installing unattended-upgrades..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" unattended-upgrades || log "Failed to install unattended-upgrades" "ERROR"
    
    log "Installing logrotate..." "INFO"
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" logrotate || log "Failed to install logrotate" "ERROR"
    
    # Configure unattended upgrades for security patches
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'APTCONF'
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APTCONF

    # Enable unattended upgrades
    echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    
    # Install and configure CrowdSec
    echo "Installing CrowdSec..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    apt-get install -y crowdsec
    
    # Configure CrowdSec with BGP-specific collections
    cscli collections install crowdsecurity/linux
    cscli collections install crowdsecurity/sshd
    
    # Add BGP/BIRD specific config for CrowdSec
    cat > /etc/crowdsec/acquis.d/bird.yaml << 'CROWDYAML'
filenames:
  - /var/log/syslog
labels:
  type: syslog
---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
CROWDYAML
    
    # Configure CrowdSec firewall bouncer
    apt-get install -y crowdsec-firewall-bouncer-iptables
    systemctl enable crowdsec-firewall-bouncer --now
    systemctl restart crowdsec
    
    # Setup base iptables rules
    echo "Configuring iptables and ip6tables firewall rules..."
    
    # Create ipset for allowed IPs (IPv4)
    ipset create bgp-allowed-ips hash:ip -exist
    ipset add bgp-allowed-ips 169.254.169.254 # Vultr BGP server
    
    # Flush existing IPv4 rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    
    # Set default policies for IPv4
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    
    # Allow SSH (rate limited)
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
    
    # Allow BGP from Vultr
    iptables -A INPUT -p tcp --dport 179 -m set --match-set bgp-allowed-ips src -j ACCEPT
    
    # Allow RPKI validators (RTR protocol) - restrict to specific trusted IPs
    iptables -A INPUT -p tcp --dport 323 -s 192.5.4.1 -j ACCEPT       # ARIN
    iptables -A INPUT -p tcp --dport 323 -s 193.0.24.0/24 -j ACCEPT   # RIPE
    iptables -A INPUT -p tcp --dport 323 -s 1.1.1.1 -j ACCEPT         # Cloudflare
    iptables -A INPUT -p tcp --dport 323 -s 1.0.0.1 -j ACCEPT         # Cloudflare
    
    # Allow all ICMP for ping/traceroute functionality
    iptables -A INPUT -p icmp -j ACCEPT
    
    # DNS resolver will be local - no need to open port 53
    
    # Log denied packets
    iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables denied: " --log-level 7
    
    # IPv6 Firewall Configuration
    # Flush existing IPv6 rules
    ip6tables -F
    ip6tables -X
    ip6tables -t mangle -F
    ip6tables -t mangle -X
    
    # Set default policies for IPv6
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT ACCEPT
    
    # Allow established connections
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    ip6tables -A INPUT -i lo -j ACCEPT
    
    # Allow SSH (rate limited)
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
    
    # Allow BGP from Vultr IPv6 (2001:19f0:ffff::1)
    ip6tables -A INPUT -p tcp --dport 179 -s 2001:19f0:ffff::1/128 -j ACCEPT
    
    # Allow RPKI validators over IPv6 - restrict to specific trusted IPs
    ip6tables -A INPUT -p tcp --dport 323 -s 2620:4f:8000::/48 -j ACCEPT      # ARIN
    ip6tables -A INPUT -p tcp --dport 323 -s 2001:67c:e0::/48 -j ACCEPT       # RIPE
    ip6tables -A INPUT -p tcp --dport 323 -s 2606:4700:4700::1111 -j ACCEPT   # Cloudflare
    ip6tables -A INPUT -p tcp --dport 323 -s 2606:4700:4700::1001 -j ACCEPT   # Cloudflare
    
    # Allow all ICMPv6 which is required for proper IPv6 operation
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
    
    # DNS resolver will be local - no need to open port 53
    
    # No need for DHCPv6 client as we're announcing our own prefixes
    
    # Log denied packets
    ip6tables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "ip6tables denied: " --log-level 7
    
    # Save iptables rules
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    
    # Configure sysctl for security
    cat > /etc/sysctl.d/99-security.conf << 'SYSCTL'
# IPv4 Security Settings
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# IPv6 Security Settings
# Disable source packet routing
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Block IPv6 redirects
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Increase system file descriptor limit
fs.file-max = 65535
SYSCTL
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-security.conf
    
    # Secure SSH access
    cat > /etc/ssh/sshd_config.d/secure_ssh.conf << 'SSHCONF'
PermitRootLogin prohibit-password
PasswordAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 20
MaxSessions 2
SSHCONF
    
    # Restart SSH service
    systemctl restart sshd
    
    # Configure logrotate for BIRD logs
    log "Configuring logrotate for BIRD and system logs..." "INFO"
    cat > /etc/logrotate.d/bird2 << 'LOGROTATECFG'
/var/log/bird*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        systemctl reload bird > /dev/null 2>&1 || true
    endscript
}
LOGROTATECFG

    # Ensure system logs are also properly rotated
    cat > /etc/logrotate.d/syslog-custom << 'SYSLOGROTATE'
/var/log/syslog
/var/log/kern.log
/var/log/auth.log
/var/log/mail.log
/var/log/cron.log
/var/log/daemon.log
/var/log/messages
{
    rotate 14
    daily
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
SYSLOGROTATE

    # Make sure permissions are correct
    chmod 644 /etc/logrotate.d/bird2
    chmod 644 /etc/logrotate.d/syslog-custom
    
    echo "Security measures configured successfully."
    # ===== END SECURITY SETUP =====
    
    # Enable and start BIRD
    systemctl enable bird
    systemctl start bird
    
    # Verify BGP sessions
    echo "Checking BGP status:"
    birdc show proto all vultr6
    
    # Check RPKI status
    echo "Checking RPKI status:"
    sleep 30  # Give RPKI time to connect
    echo "Routinator status:"
    birdc show protocols rpki_routinator
    echo "ARIN validator status:" 
    birdc show protocols rpki_arin
    echo "RIPE validator status:"
    birdc show protocols rpki_ripe
    echo "Cloudflare validator status:"
    birdc show protocols rpki_cloudflare
    
    # Check Routinator service
    echo "Routinator service status:"
    systemctl status routinator
    
    # Check security services
    echo "CrowdSec status:"
    systemctl status crowdsec
    echo "Fail2ban status:"
    systemctl status fail2ban
EOF
  
  echo "IPv6 BIRD configuration deployed to $server_type server"
}

# Function to check if existing VM is shut down
check_existing_vm() {
  echo "Checking if existing birdbgp-losangeles VM is shut down..."
  
  # Search for VM by label
  existing_vm=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances?label=birdbgp-losangeles" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  # Check if VM exists
  vm_id=$(echo $existing_vm | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ -z "$vm_id" ]; then
    echo "No existing birdbgp-losangeles VM found. Proceeding with deployment."
    return 0
  fi
  
  # Check VM status
  vm_status=$(echo $existing_vm | grep -o '"status":"[^"]*' | cut -d'"' -f4)
  
  if [ "$vm_status" == "active" ]; then
    echo "ERROR: Existing birdbgp-losangeles VM is still active!"
    echo "Please shut down the VM before proceeding with deployment."
    echo "VM ID: $vm_id"
    echo ""
    echo "To shut down the VM, you can use Vultr's control panel or API:"
    echo "curl -X POST \"${VULTR_API_ENDPOINT}instances/$vm_id/halt\" -H \"Authorization: Bearer \${VULTR_API_KEY}\""
    return 1
  elif [ "$vm_status" == "stopped" ]; then
    echo "WARNING: Existing birdbgp-losangeles VM is stopped but not destroyed."
    echo "You may want to destroy it after successful deployment."
    echo "VM ID: $vm_id"
    echo ""
    echo "To destroy the VM, you can use Vultr's control panel or API:"
    echo "curl -X DELETE \"${VULTR_API_ENDPOINT}instances/$vm_id\" -H \"Authorization: Bearer \${VULTR_API_KEY}\""
    
    # Prompt for confirmation to continue
    read -p "Continue with deployment anyway? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
      echo "Deployment aborted."
      return 1
    fi
    return 0
  else
    echo "Existing birdbgp-losangeles VM is in state: $vm_status"
    echo "This appears to be safe for proceeding with deployment."
    return 0
  fi
}

# Function to clean up reserved IPs
cleanup_reserved_ips() {
  log "Cleaning up unused reserved IPs to stay within Vultr limits..." "INFO"
  
  # Get all reserved IPs
  reserved_ips_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  # Parameter to control whether to delete all IPs or just unused ones
  local delete_all=${1:-false}
  
  # Show how many IPs we found
  local total_count=$(echo "$reserved_ips_response" | grep -o '"id":"[^"]*"' | wc -l)
  log "Found $total_count total reserved IPs in your account" "INFO"
  
  # First handle IPs with our recognized pattern
  log "Processing reserved IPs matching our naming pattern..." "INFO"
  echo "$reserved_ips_response" | grep -o '{[^{]*"id":"[^"]*"[^}]*"label":"floating-ip[^"]*"[^}]*}' | while read -r ip_obj; do
    ip_id=$(echo "$ip_obj" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    ip_label=$(echo "$ip_obj" | grep -o '"label":"[^"]*' | cut -d'"' -f4)
    ip_subnet=$(echo "$ip_obj" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
    instance_id=$(echo "$ip_obj" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4)
    
    # If delete_all=true OR (instance_id is empty string or "null", it's not attached)
    if [ "$delete_all" = "true" ] || [ -z "$instance_id" ] || [ "$instance_id" = "null" ] || [ "$instance_id" = '""' ]; then
      if [ "$delete_all" = "true" ] && [ ! -z "$instance_id" ] && [ "$instance_id" != "null" ] && [ "$instance_id" != '""' ]; then
        log "Detaching and deleting reserved IP: $ip_label - $ip_subnet (ID: $ip_id) from instance $instance_id" "INFO"
        
        # Detach first
        detach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips/$ip_id/detach" \
          -H "Authorization: Bearer ${VULTR_API_KEY}")
        log "Detach response: $detach_response" "INFO"
        
        # Wait for detachment to complete
        sleep 3
      else
        log "Deleting unused reserved IP: $ip_label - $ip_subnet (ID: $ip_id)" "INFO"
      fi
      
      # Now delete the IP
      delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}reserved-ips/$ip_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
      
      if [ -z "$delete_response" ]; then
        log "Successfully deleted reserved IP $ip_label" "INFO"
      else
        log "Failed to delete reserved IP $ip_label: $delete_response" "WARN"
      fi
      
      # Wait a moment between deletions to avoid API rate limits
      sleep 1
    else
      log "Skipping attached reserved IP: $ip_label (attached to instance $instance_id)" "INFO"
    fi
  done
  
  # Now look for any other IPs without labels or with non-standard labels, if delete_all=true
  if [ "$delete_all" = "true" ]; then
    log "Looking for other reserved IPs not matching our naming pattern..." "INFO"
    echo "$reserved_ips_response" | grep -o '{[^}]*}' | while read -r ip_obj; do
      # Skip if this is one of our labeled IPs we already processed
      if [[ "$ip_obj" == *'"label":"floating-ip'* ]]; then
        continue
      fi
      
      ip_id=$(echo "$ip_obj" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      if [ -z "$ip_id" ]; then
        continue
      fi
      
      ip_label=$(echo "$ip_obj" | grep -o '"label":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "no-label")
      ip_subnet=$(echo "$ip_obj" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "unknown-ip")
      instance_id=$(echo "$ip_obj" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "")
      
      # If it has an instance ID, detach first
      if [ ! -z "$instance_id" ] && [ "$instance_id" != "null" ] && [ "$instance_id" != '""' ]; then
        log "Detaching other reserved IP: $ip_label - $ip_subnet (ID: $ip_id) from instance $instance_id" "INFO"
        
        # Detach first
        detach_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips/$ip_id/detach" \
          -H "Authorization: Bearer ${VULTR_API_KEY}")
        log "Detach response: $detach_response" "INFO"
        
        # Wait for detachment to complete
        sleep 3
      fi
      
      # Now delete the IP
      log "Deleting other reserved IP: $ip_label - $ip_subnet (ID: $ip_id)" "INFO"
      delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}reserved-ips/$ip_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
      
      if [ -z "$delete_response" ]; then
        log "Successfully deleted reserved IP $ip_label" "INFO"
      else
        log "Failed to delete reserved IP $ip_label: $delete_response" "WARN"
      fi
      
      # Wait a moment between deletions to avoid API rate limits
      sleep 1
    done
  fi
  
  log "Reserved IP cleanup completed" "INFO"
}

# Main deployment function
deploy() {
  # Enable verbose debugging to see exactly what's happening
  set -x
  
  # Set up error handling
  # If the script exits with an error, run the cleanup function
  trap 'echo "Error detected, cleaning up resources..."; set +x; cleanup_resources; exit 1' ERR
  
  echo "Starting Vultr BGP Anycast deployment..."
  
  # Clean up unused reserved IPs if enabled
  if [ "$CLEANUP_RESERVED_IPS" = "true" ]; then
    log "Running pre-deployment cleanup of unused reserved IPs..." "INFO"
    
    # First try to clean up only unused IPs
    cleanup_reserved_ips "false"  # Only delete unused IPs
    
    # Check if we still have IPs that might be preventing deployment
    local current_ips=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    local total_count=$(echo "$current_ips" | grep -o '"id":"[^"]*"' | wc -l)
    log "After initial cleanup: Found $total_count total reserved IPs in your account" "INFO"
    
    # If we still have a lot of IPs, more aggressive cleanup may be needed
    if [ "$total_count" -ge 2 ]; then
      log "WARNING: You still have $total_count reserved IPs after cleanup" "WARN"
      log "This may exceed Vultr's quota limits for your account" "WARN"
      
      read -p "Would you like to perform a more aggressive cleanup of ALL reserved IPs? (y/n): " cleanup_all
      if [[ $cleanup_all =~ ^[Yy]$ ]]; then
        log "Performing aggressive cleanup of ALL reserved IPs..." "INFO"
        cleanup_reserved_ips "true"  # Delete all IPs, including attached ones
      else
        log "Continuing with deployment without additional cleanup" "INFO"
      fi
    fi
  fi
  
  # Check if existing VM is shut down
  check_existing_vm || exit 1
  
  # Check for potentially incomplete previous deployment
  log "Checking for existing BGP Anycast resources from a previous deployment..." "INFO"
  
  # Check for existing instances with our naming pattern
  existing_instances_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  # Build instance patterns dynamically from region variables
  # This ensures we find instances in the configured regions, not hardcoded ones
  instance_patterns=()
  instance_patterns+=("${IPV4_REGION_PRIMARY}-ipv4-bgp-primary")
  instance_patterns+=("${IPV4_REGION_SECONDARY}-ipv4-bgp-secondary")
  instance_patterns+=("${IPV4_REGION_TERTIARY}-ipv4-bgp-tertiary")
  instance_patterns+=("${IPV6_REGION}-ipv6-bgp")
  existing_instances=()
  existing_instance_details=""
  
  for pattern in "${instance_patterns[@]}"; do
    if echo "$existing_instances_response" | grep -q "\"label\":\"$pattern"; then
      id=$(echo "$existing_instances_response" | grep -o "\"id\":\"[^\"]*\",\"os\":\"[^\"]*\",\"ram\":[^,]*,\"disk\":[^,]*,\"main_ip\":\"[^\"]*\",\"vcpu_count\":[^,]*,\"region\":\"[^\"]*\",\"plan\":\"[^\"]*\",\"date_created\":\"[^\"]*\",\"status\":\"[^\"]*\",\"allowed_bandwidth\":[^,]*,\"netmask_v4\":\"[^\"]*\",\"gateway_v4\":\"[^\"]*\",\"power_status\":\"[^\"]*\",\"server_status\":\"[^\"]*\",\"v6_network\":\"[^\"]*\",\"v6_main_ip\":\"[^\"]*\",\"v6_network_size\":[^,]*,\"label\":\"$pattern[^\"]*\"" | head -1)
      server_id=$(echo "$id" | grep -o "\"id\":\"[^\"]*\"" | cut -d'"' -f4)
      main_ip=$(echo "$id" | grep -o "\"main_ip\":\"[^\"]*\"" | cut -d'"' -f4)
      region=$(echo "$id" | grep -o "\"region\":\"[^\"]*\"" | cut -d'"' -f4)
      label=$(echo "$id" | grep -o "\"label\":\"[^\"]*\"" | cut -d'"' -f4)
      status=$(echo "$id" | grep -o "\"status\":\"[^\"]*\"" | cut -d'"' -f4)
      
      existing_instances+=("$server_id")
      existing_instance_details+="  • $label ($region): $main_ip (Status: $status, ID: $server_id)\n"
    fi
  done
  
  # Also check for reserved IPs
  reserved_ips_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  total_ip_count=$(echo "$reserved_ips_response" | grep -o '"id":"[^"]*"' | wc -l)
  existing_reserved_details=""
  
  if [ "$total_ip_count" -gt 0 ]; then
    echo "$reserved_ips_response" | grep -o '"id":"[^"]*","region":"[^"]*","ip_type":"[^"]*","subnet":"[^"]*","subnet_size":[^,]*,"label":"[^"]*"' | \
    while read -r line; do
      id=$(echo "$line" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      region=$(echo "$line" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
      ip_type=$(echo "$line" | grep -o '"ip_type":"[^"]*' | cut -d'"' -f4)
      subnet=$(echo "$line" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      label=$(echo "$line" | grep -o '"label":"[^"]*' | cut -d'"' -f4)
      
      existing_reserved_details+="  • ${ip_type}: $subnet (${region}) - $label\n"
    done
  fi
  
  # If we found existing resources, ask user what to do
  if [ ${#existing_instances[@]} -gt 0 ] || [ "$total_ip_count" -gt 0 ]; then
    log "Found existing BGP Anycast resources that appear to be from a previous deployment:" "WARN"
    echo ""
    
    if [ ${#existing_instances[@]} -gt 0 ]; then
      echo "EXISTING INSTANCES:"
      echo -e "$existing_instance_details"
      echo ""
    fi
    
    if [ "$total_ip_count" -gt 0 ]; then
      echo "EXISTING RESERVED IPs:"
      echo -e "$existing_reserved_details"
      echo ""
    fi
    
    echo "Options:"
    echo "1) Clean up all existing resources and start fresh"
    echo "2) Continue deployment using existing resources where possible"
    echo "3) Cancel deployment"
    echo ""
    
    read -p "What would you like to do? (1-3): " recovery_choice
    
    case "$recovery_choice" in
      1)
        log "Cleaning up all existing resources before starting fresh deployment..." "INFO"
        
        # Clean up instances
        for instance_id in "${existing_instances[@]}"; do
          log "Deleting instance with ID: $instance_id" "INFO"
          delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}instances/$instance_id" \
            -H "Authorization: Bearer ${VULTR_API_KEY}")
        done
        
        # Clean up reserved IPs
        log "Cleaning up all reserved IPs..." "INFO"
        cleanup_reserved_ips "true"
        
        # Wait for deletion to complete
        log "Waiting 30 seconds for resource deletion to complete..." "INFO"
        sleep 30
        ;;
      2)
        log "Continuing deployment with existing resources..." "INFO"
        log "WARNING: This is experimental and may not work correctly." "WARN"
        log "If you encounter errors, please try again with a clean deployment." "WARN"
        # We'll continue with deployment and try to use existing resources
        # (The script will create new resources only where needed)
        ;;
      3)
        log "Deployment cancelled by user." "INFO"
        exit 0
        ;;
      *)
        log "Invalid choice. Exiting for safety." "ERROR"
        exit 1
        ;;
    esac
  fi
  
  # Automatically check for existing reserved IPs and clean up if needed
  log "Checking for existing reserved IPs before deployment..." "INFO"
  reserved_ips_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  # Build instance patterns dynamically from region variables
  # This ensures we find instances in the configured regions, not hardcoded ones
  instance_patterns=()
  instance_patterns+=("${IPV4_REGION_PRIMARY}-ipv4-bgp-primary")
  instance_patterns+=("${IPV4_REGION_SECONDARY}-ipv4-bgp-secondary")
  instance_patterns+=("${IPV4_REGION_TERTIARY}-ipv4-bgp-tertiary")
  instance_patterns+=("${IPV6_REGION}-ipv6-bgp")
  existing_instances=()
  existing_instance_details=""
  
  for pattern in "${instance_patterns[@]}"; do
    if echo "$existing_instances_response" | grep -q "\"label\":\"$pattern"; then
      id=$(echo "$existing_instances_response" | grep -o "\"id\":\"[^\"]*\",\"os\":\"[^\"]*\",\"ram\":[^,]*,\"disk\":[^,]*,\"main_ip\":\"[^\"]*\",\"vcpu_count\":[^,]*,\"region\":\"[^\"]*\",\"plan\":\"[^\"]*\",\"date_created\":\"[^\"]*\",\"status\":\"[^\"]*\",\"allowed_bandwidth\":[^,]*,\"netmask_v4\":\"[^\"]*\",\"gateway_v4\":\"[^\"]*\",\"power_status\":\"[^\"]*\",\"server_status\":\"[^\"]*\",\"v6_network\":\"[^\"]*\",\"v6_main_ip\":\"[^\"]*\",\"v6_network_size\":[^,]*,\"label\":\"$pattern[^\"]*\"" | head -1)
      server_id=$(echo "$id" | grep -o "\"id\":\"[^\"]*\"" | cut -d'"' -f4)
      main_ip=$(echo "$id" | grep -o "\"main_ip\":\"[^\"]*\"" | cut -d'"' -f4)
      region=$(echo "$id" | grep -o "\"region\":\"[^\"]*\"" | cut -d'"' -f4)
      label=$(echo "$id" | grep -o "\"label\":\"[^\"]*\"" | cut -d'"' -f4)
      status=$(echo "$id" | grep -o "\"status\":\"[^\"]*\"" | cut -d'"' -f4)
      
      existing_instances+=("$server_id")
      existing_instance_details+="  • $label ($region): $main_ip (Status: $status, ID: $server_id)"$'\n'
    fi
  done
  
  # Also check for reserved IPs
  reserved_ips_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  total_ip_count=$(echo "$reserved_ips_response" | grep -o '"id":"[^"]*"' | wc -l)
  existing_reserved_details=""
  
  if [ "$total_ip_count" -gt 0 ]; then
    echo "$reserved_ips_response" | grep -o '"id":"[^"]*","region":"[^"]*","ip_type":"[^"]*","subnet":"[^"]*","subnet_size":[^,]*,"label":"[^"]*"' | \
    while read -r line; do
      id=$(echo "$line" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      region=$(echo "$line" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
      ip_type=$(echo "$line" | grep -o '"ip_type":"[^"]*' | cut -d'"' -f4)
      subnet=$(echo "$line" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      label=$(echo "$line" | grep -o '"label":"[^"]*' | cut -d'"' -f4)
      
      existing_reserved_details+="  • ${ip_type}: $subnet (${region}) - $label"$'\n'
    done
  fi
  
  # If we found existing resources, ask user what to do
  if [ ${#existing_instances[@]} -gt 0 ] || [ "$total_ip_count" -gt 0 ]; then
    log "Found existing BGP Anycast resources that appear to be from a previous deployment:" "WARN"
    echo ""
    
    if [ ${#existing_instances[@]} -gt 0 ]; then
      echo "EXISTING INSTANCES:"
      echo -e "$existing_instance_details"
      echo ""
    fi
    
    if [ "$total_ip_count" -gt 0 ]; then
      echo "EXISTING RESERVED IPs:"
      echo -e "$existing_reserved_details"
      echo ""
    fi
    
    echo "Options:"
    echo "1) Clean up all existing resources and start fresh"
    echo "2) Continue deployment using existing resources where possible"
    echo "3) Cancel deployment"
    echo ""
    
    read -p "What would you like to do? (1-3): " recovery_choice
    
    case "$recovery_choice" in
      1)
        log "Cleaning up all existing resources before starting fresh deployment..." "INFO"
        
        # Clean up instances
        for instance_id in "${existing_instances[@]}"; do
          log "Deleting instance with ID: $instance_id" "INFO"
          delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}instances/$instance_id" \
            -H "Authorization: Bearer ${VULTR_API_KEY}")
        done
        
        # Clean up reserved IPs
        log "Cleaning up all reserved IPs..." "INFO"
        cleanup_reserved_ips "true"
        
        # Wait for deletion to complete
        log "Waiting 30 seconds for resource deletion to complete..." "INFO"
        sleep 30
        ;;
      2)
        log "Continuing deployment with existing resources..." "INFO"
        log "WARNING: This is experimental and may not work correctly." "WARN"
        log "If you encounter errors, please try again with a clean deployment." "WARN"
        # We'll continue with deployment and try to use existing resources
        # (The script will create new resources only where needed)
        ;;
      3)
        log "Deployment cancelled by user." "INFO"
        exit 0
        ;;
      *)
        log "Invalid choice. Exiting for safety." "ERROR"
        exit 1
        ;;
    esac
  fi
  
  total_ip_count=$(echo "$reserved_ips_response" | grep -o '"id":"[^"]*"' | wc -l)
  existing_reserved_details=""
  
  if [ "$total_ip_count" -gt 0 ]; then
    echo "$reserved_ips_response" | grep -o '"id":"[^"]*","region":"[^"]*","ip_type":"[^"]*","subnet":"[^"]*","subnet_size":[^,]*,"label":"[^"]*"' | \
    while read -r line; do
      id=$(echo "$line" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      region=$(echo "$line" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
      ip_type=$(echo "$line" | grep -o '"ip_type":"[^"]*' | cut -d'"' -f4)
      subnet=$(echo "$line" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      label=$(echo "$line" | grep -o '"label":"[^"]*' | cut -d'"' -f4)
      
      existing_reserved_details+="  • ${ip_type}: $subnet (${region}) - $label"$'\n'
    done
  fi
  
  # If we found existing resources, ask user what to do
  if [ ${#existing_instances[@]} -gt 0 ] || [ "$total_ip_count" -gt 0 ]; then
    log "Found existing BGP Anycast resources that appear to be from a previous deployment:" "WARN"
    echo ""
    
    if [ ${#existing_instances[@]} -gt 0 ]; then
      echo "EXISTING INSTANCES:"
      echo -e "$existing_instance_details"
      echo ""
    fi
    
    if [ "$total_ip_count" -gt 0 ]; then
      echo "EXISTING RESERVED IPs:"
      echo -e "$existing_reserved_details"
      echo ""
    fi
    
    echo "Options:"
    echo "1) Clean up all existing resources and start fresh"
    echo "2) Continue deployment using existing resources where possible"
    echo "3) Cancel deployment"
    echo ""
    
    read -p "What would you like to do? (1-3): " recovery_choice
    
    case "$recovery_choice" in
      1)
        log "Cleaning up all existing resources before starting fresh deployment..." "INFO"
        
        # Clean up instances
        for instance_id in "${existing_instances[@]}"; do
          log "Deleting instance with ID: $instance_id" "INFO"
          delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}instances/$instance_id" \
            -H "Authorization: Bearer ${VULTR_API_KEY}")
        done
        
        # Clean up reserved IPs
        log "Cleaning up all reserved IPs..." "INFO"
        cleanup_reserved_ips "true"
        
        # Wait for deletion to complete
        log "Waiting 30 seconds for resource deletion to complete..." "INFO"
        sleep 30
        ;;
      2)
        log "Continuing deployment with existing resources..." "INFO"
        log "WARNING: This is experimental and may not work correctly." "WARN"
        log "If you encounter errors, please try again with a clean deployment." "WARN"
        # We'll continue with deployment and try to use existing resources
        # (The script will create new resources only where needed)
        ;;
      3)
        log "Deployment cancelled by user." "INFO"
        exit 0
        ;;
      *)
        log "Invalid choice. Exiting for safety." "ERROR"
        exit 1
        ;;
    esac
  fi
  
  # Automatically check for existing reserved IPs and clean up if needed
  log "Checking for existing reserved IPs before deployment..." "INFO"
  reserved_ips_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  total_count=$(echo "$reserved_ips_response" | grep -o '"id":"[^"]*"' | wc -l)
  log "Found $total_count total reserved IPs in your account" "INFO"
  
  if [ "$total_count" -gt 0 ]; then
    log "WARNING: Found existing reserved IPs that could prevent deployment due to quota limits" "WARN"
    echo "$reserved_ips_response" | grep -o '"id":"[^"]*","region":"[^"]*","ip_type":"[^"]*","subnet":"[^"]*","subnet_size":[^,]*,"label":"[^"]*"' | \
    while read -r line; do
      id=$(echo "$line" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      region=$(echo "$line" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
      ip_type=$(echo "$line" | grep -o '"ip_type":"[^"]*' | cut -d'"' -f4)
      subnet=$(echo "$line" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      label=$(echo "$line" | grep -o '"label":"[^"]*' | cut -d'"' -f4)
      
      echo "  • ${ip_type}: $subnet (${region}) - $label"
    done
    
    read -p "Would you like to clean up ALL existing reserved IPs before proceeding? (y/n): " cleanup_all
    if [[ $cleanup_all =~ ^[Yy]$ ]]; then
      log "Performing complete cleanup of ALL reserved IPs..." "INFO"
      cleanup_reserved_ips "true"  # Force delete all IPs
    else
      log "Continuing without cleanup - note this might cause quota limit errors" "WARN"
    fi
  else
    log "No existing reserved IPs found - good to proceed" "INFO"
  fi
  
  # Deploy according to selected IP stack mode
  case "${IP_STACK_MODE:-dual}" in
    ipv4)
      log "Deploying IPv4-only BGP Anycast infrastructure..." "INFO"
      
      # Create IPv4 instances (3 servers as per documentation)
      create_instance "${IPV4_REGIONS[0]}" "ewr-ipv4-bgp-primary-1c1g" "1" "false" || { echo "Failed to create primary instance"; exit 1; }
      create_instance "${IPV4_REGIONS[1]}" "mia-ipv4-bgp-secondary-1c1g" "2" "false" || { echo "Failed to create secondary instance"; exit 1; }
      create_instance "${IPV4_REGIONS[2]}" "ord-ipv4-bgp-tertiary-1c1g" "3" "false" || { echo "Failed to create tertiary instance"; exit 1; }
      
      # Create floating IPs for IPv4 instances
      create_floating_ip "$(cat ewr-ipv4-bgp-primary-1c1g_id.txt)" "${IPV4_REGIONS[0]}" "ipv4" || { echo "Failed to create floating IP for primary instance"; exit 1; }
      create_floating_ip "$(cat mia-ipv4-bgp-secondary-1c1g_id.txt)" "${IPV4_REGIONS[1]}" "ipv4" || { echo "Failed to create floating IP for secondary instance"; exit 1; }
      create_floating_ip "$(cat ord-ipv4-bgp-tertiary-1c1g_id.txt)" "${IPV4_REGIONS[2]}" "ipv4" || { echo "Failed to create floating IP for tertiary instance"; exit 1; }
      
      # Generate BIRD configurations
      generate_ipv4_bird_config "ewr-ipv4-primary" "$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)" 0
      generate_ipv4_bird_config "mia-ipv4-secondary" "$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)" 1
      generate_ipv4_bird_config "ord-ipv4-tertiary" "$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)" 2
      ;;
      
    ipv6)
      log "Deploying IPv6-only BGP Anycast infrastructure..." "INFO"
      
      # Create IPv6 instance
      create_instance "${IPV6_REGION}" "lax-ipv6-bgp-1c1g" "1" "true" || { echo "Failed to create IPv6 instance"; exit 1; }
      
      # Create floating IP for IPv6 instance
      create_floating_ip "$(cat lax-ipv6-bgp-1c1g_id.txt)" "${IPV6_REGION}" "ipv6" || { echo "Failed to create floating IP for IPv6 instance"; exit 1; }
      
      # Generate BIRD configuration
      generate_ipv6_bird_config "lax-ipv6" "$(cat lax-ipv6-bgp-1c1g_ipv4.txt)" "$(cat lax-ipv6-bgp-1c1g_ipv6.txt)"
      ;;
      
    dual|*)
      log "Deploying dual-stack BGP Anycast infrastructure..." "INFO"
      
      # Create IPv4 instances (3 servers as per documentation)
      create_instance "${IPV4_REGIONS[0]}" "ewr-ipv4-bgp-primary-1c1g" "1" "false" || { echo "Failed to create primary instance"; exit 1; }
      create_instance "${IPV4_REGIONS[1]}" "mia-ipv4-bgp-secondary-1c1g" "2" "false" || { echo "Failed to create secondary instance"; exit 1; }
      create_instance "${IPV4_REGIONS[2]}" "ord-ipv4-bgp-tertiary-1c1g" "3" "false" || { echo "Failed to create tertiary instance"; exit 1; }
      
      # Create IPv6 instance (1 server as per documentation)
      create_instance "${IPV6_REGION}" "lax-ipv6-bgp-1c1g" "1" "true" || { echo "Failed to create IPv6 instance"; exit 1; }
      
      # Create floating IPs for each instance
      create_floating_ip "$(cat ewr-ipv4-bgp-primary-1c1g_id.txt)" "${IPV4_REGIONS[0]}" "ipv4" || { echo "Failed to create floating IP for primary instance"; exit 1; }
      create_floating_ip "$(cat mia-ipv4-bgp-secondary-1c1g_id.txt)" "${IPV4_REGIONS[1]}" "ipv4" || { echo "Failed to create floating IP for secondary instance"; exit 1; }
      create_floating_ip "$(cat ord-ipv4-bgp-tertiary-1c1g_id.txt)" "${IPV4_REGIONS[2]}" "ipv4" || { echo "Failed to create floating IP for tertiary instance"; exit 1; }
      create_floating_ip "$(cat lax-ipv6-bgp-1c1g_id.txt)" "${IPV6_REGION}" "ipv6" || { echo "Failed to create floating IP for IPv6 instance"; exit 1; }
      
      # Generate BIRD configurations
      generate_ipv4_bird_config "ewr-ipv4-primary" "$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)" 0
      generate_ipv4_bird_config "mia-ipv4-secondary" "$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)" 1
      generate_ipv4_bird_config "ord-ipv4-tertiary" "$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)" 2
      generate_ipv6_bird_config "lax-ipv6" "$(cat lax-ipv6-bgp-1c1g_ipv4.txt)" "$(cat lax-ipv6-bgp-1c1g_ipv6.txt)"
      ;;
  esac
  
  # Store the existing VM ID for potential cleanup
  existing_vm=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances?label=birdbgp-losangeles" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  vm_id=$(echo $existing_vm | grep -o '"id":"[^"]*' | cut -d'"' -f4)
  
  if [ ! -z "$vm_id" ]; then
    echo "$vm_id" > "birdbgp-losangeles_old_id.txt"
  fi
  
  # Generate BIRD configurations
  generate_ipv4_bird_config "ewr-ipv4-primary" "$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)" 0
  generate_ipv4_bird_config "mia-ipv4-secondary" "$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)" 1
  generate_ipv4_bird_config "ord-ipv4-tertiary" "$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)" 2
  generate_ipv6_bird_config "lax-ipv6" "$(cat lax-ipv6-bgp-1c1g_ipv4.txt)" "$(cat lax-ipv6-bgp-1c1g_ipv6.txt)"
  
  # Perform a detailed diagnostic after configuration generation
  log "DIAGNOSTIC: Listing all files after configuration generation:" "DEBUG"
  ls -la | while read -r line; do log "  $line" "DEBUG"; done
  
  # Check for floating IP files specifically and print their contents if found
  log "DIAGNOSTIC: Looking for floating IP files..." "DEBUG"
  for region in "${IPV4_REGIONS[@]}"; do
    for format in "floating_ipv4_${region}.txt" "floating-ipv4-${region}.txt" "floating-ip4-${region}.txt"; do
      if [ -f "$format" ]; then
        log "DIAGNOSTIC: Found $format with content: $(cat "$format")" "DEBUG"
      else
        log "DIAGNOSTIC: File $format does not exist" "DEBUG"
      fi
    done
  done
  
  # Check IPv6 floating IP files
  for format in "floating_ipv6_${IPV6_REGION}.txt" "floating-ipv6-${IPV6_REGION}.txt" "floating-ip6-${IPV6_REGION}.txt"; do
    if [ -f "$format" ]; then
      log "DIAGNOSTIC: Found $format with content: $(cat "$format")" "DEBUG"
    else
      log "DIAGNOSTIC: File $format does not exist" "DEBUG"
    fi
  done
  
  # Add detailed debugging logs to help diagnose the issue
  log "Debugging verification: Beginning pre-deployment file check..." "DEBUG"
  log "Current working directory: $(pwd)" "DEBUG"
  log "File listing before deployment:" "DEBUG"
  ls -la | while read -r line; do log "  $line" "DEBUG"; done
  
  # Verify all required files exist before attempting deployment
  local deployment_files_ok=true
  local required_files=(
    "ewr-ipv4-bgp-primary-1c1g_ipv4.txt"
    "mia-ipv4-bgp-secondary-1c1g_ipv4.txt"
    "ord-ipv4-bgp-tertiary-1c1g_ipv4.txt"
    "lax-ipv6-bgp-1c1g_ipv4.txt"
    "floating_ipv4_${IPV4_REGIONS[0]}.txt"
    "floating_ipv4_${IPV4_REGIONS[1]}.txt"
    "floating_ipv4_${IPV4_REGIONS[2]}.txt"
    "floating_ipv6_${IPV6_REGION}.txt"
  )
  
  # Create any missing files from the variants that do exist
  log "Attempting to create any missing required files from existing ones..." "INFO"
  
  # Define all possible format variants for IPv4 and IPv6
  for region in "${IPV4_REGIONS[@]}"; do
    # Format variations for IPv4
    for target in "floating_ipv4_${region}.txt" "floating-ipv4-${region}.txt" "floating_ip4_${region}.txt" "floating-ip4-${region}.txt"; do
      # If target doesn't exist, check for any other variant and copy it
      if [ ! -f "$target" ]; then
        for source in "floating_ipv4_${region}.txt" "floating-ipv4-${region}.txt" "floating_ip4_${region}.txt" "floating-ip4-${region}.txt"; do
          if [ -f "$source" ] && [ "$source" != "$target" ]; then
            log "Creating $target from $source" "INFO"
            cp "$source" "$target"
            break
          fi
        done
      fi
    done
  done
  
  # Do the same for IPv6
  for target in "floating_ipv6_${IPV6_REGION}.txt" "floating-ipv6-${IPV6_REGION}.txt" "floating_ip6_${IPV6_REGION}.txt" "floating-ip6-${IPV6_REGION}.txt"; do
    if [ ! -f "$target" ]; then
      for source in "floating_ipv6_${IPV6_REGION}.txt" "floating-ipv6-${IPV6_REGION}.txt" "floating_ip6_${IPV6_REGION}.txt" "floating-ip6-${IPV6_REGION}.txt"; do
        if [ -f "$source" ] && [ "$source" != "$target" ]; then
          log "Creating $target from $source" "INFO"
          cp "$source" "$target"
          break
        fi
      done
    fi
  done
  
  # Check existence of each file with detailed logging
  log "Checking for required files:" "DEBUG"
  for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
      log "File exists: $file ($(cat "$file"))" "DEBUG"
    else
      log "Error: Required file $file is missing. Cannot proceed with deployment." "ERROR"
      deployment_files_ok=false
    fi
  done
  
  # Check IPV4_REGIONS and IPV6_REGION variables
  log "IPV4_REGIONS: ${IPV4_REGIONS[*]}" "DEBUG"
  log "IPV6_REGION: ${IPV6_REGION}" "DEBUG"
  
  if [ "$deployment_files_ok" != "true" ]; then
    log "Deployment cannot continue due to missing files. Please check the log for details." "ERROR"
    return 1
  fi
  
  # Deploy BIRD configurations
  deploy_ipv4_bird_config "ewr-ipv4-primary" "$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)" "$(cat floating_ipv4_${IPV4_REGIONS[0]}.txt)"
  deploy_ipv4_bird_config "mia-ipv4-secondary" "$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)" "$(cat floating_ipv4_${IPV4_REGIONS[1]}.txt)"
  deploy_ipv4_bird_config "ord-ipv4-tertiary" "$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)" "$(cat floating_ipv4_${IPV4_REGIONS[2]}.txt)"
  deploy_ipv6_bird_config "lax-ipv6" "$(cat lax-ipv6-bgp-1c1g_ipv4.txt)" "$(cat floating_ipv6_${IPV6_REGION}.txt)"
  
  echo "Deployment complete!"
  echo ""
  
  # Verify required files exist before displaying server information
  if [ ! -f "ewr-ipv4-bgp-primary-1c1g_ipv4.txt" ] || [ ! -f "floating_ipv4_${IPV4_REGIONS[0]}.txt" ]; then
    log "Error: Required server information files not found" "ERROR"
    return 1
  fi
  
  echo "IPv4 BGP Servers:"
  echo "Primary (Newark): $(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt) with floating IP $(cat floating_ipv4_${IPV4_REGIONS[0]}.txt)"
  echo "Secondary (Miami): $(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt) with floating IP $(cat floating_ipv4_${IPV4_REGIONS[1]}.txt)"
  echo "Tertiary (Chicago): $(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt) with floating IP $(cat floating_ipv4_${IPV4_REGIONS[2]}.txt)"
  echo ""
  echo "IPv6 BGP Server:"
  echo "IPv6 Server (Los Angeles): $(cat lax-ipv6-bgp-1c1g_ipv4.txt) (IPv6: $(cat lax-ipv6-bgp-1c1g_ipv6.txt)) with floating IPv6 $(cat floating_ipv6_${IPV6_REGION}.txt)"
  echo ""
  echo "To test failover, SSH to the primary server and run: systemctl stop bird"
  echo "Then check that traffic is redirected to the secondary server."
  
  # Remove the error trap as deployment completed successfully
  trap - ERR
}

# Monitor function
monitor() {
  echo "Monitoring BGP Anycast infrastructure..."
  
  # Check if instance ID files exist
  if [ ! -f "ewr-ipv4-bgp-primary-1c1g_id.txt" ] || [ ! -f "mia-ipv4-bgp-secondary-1c1g_id.txt" ] || [ ! -f "ord-ipv4-bgp-tertiary-1c1g_id.txt" ] || [ ! -f "lax-ipv6-bgp-1c1g_id.txt" ]; then
    echo "Error: Instance ID files not found. Have you deployed the infrastructure?"
    exit 1
  fi
  
  # Get instance IDs
  ipv4_primary_id=$(cat ewr-ipv4-bgp-primary-1c1g_id.txt)
  ipv4_secondary_id=$(cat mia-ipv4-bgp-secondary-1c1g_id.txt)
  ipv4_tertiary_id=$(cat ord-ipv4-bgp-tertiary-1c1g_id.txt)
  ipv6_id=$(cat lax-ipv6-bgp-1c1g_id.txt)
  
  # Get instance IPs
  ipv4_primary_ip=$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)
  ipv4_secondary_ip=$(cat mia-ipv4-bgp-secondary-1c1g_ipv4.txt)
  ipv4_tertiary_ip=$(cat ord-ipv4-bgp-tertiary-1c1g_ipv4.txt)
  ipv6_ip=$(cat lax-ipv6-bgp-1c1g_ipv4.txt)
  
  # Check instance status
  echo "Checking instance status..."
  
  for id in "$ipv4_primary_id" "$ipv4_secondary_id" "$ipv4_tertiary_id" "$ipv6_id"; do
    status=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    echo "Instance $id status: $status"
  done
  
  # Check floating IP status
  echo "Checking floating IP status..."
  
  for region in "${IPV4_REGIONS[@]}" "${IPV6_REGION}"; do
    if [ -f "floating_ipv4_${region}_id.txt" ]; then
      floating_id=$(cat "floating_ipv4_${region}_id.txt")
      floating_ip=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
      
      echo "Floating IPv4 in $region: $floating_ip"
    fi
    
    if [ -f "floating_ipv6_${region}_id.txt" ]; then
      floating_id=$(cat "floating_ipv6_${region}_id.txt")
      floating_ip=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips/$floating_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
      
      echo "Floating IPv6 in $region: $floating_ip"
    fi
  done
  
  # Check BGP status on each server
  echo "Checking BGP status on IPv4 primary server..."
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show proto all vultr"
  
  echo "Checking BGP status on IPv4 secondary server..."
  ssh $SSH_OPTIONS root@$ipv4_secondary_ip "birdc show proto all vultr"
  
  echo "Checking BGP status on IPv4 tertiary server..."
  ssh $SSH_OPTIONS root@$ipv4_tertiary_ip "birdc show proto all vultr"
  
  echo "Checking BGP status on IPv6 server..."
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show proto all vultr6"
  
  # Check RPKI status on each server
  echo "Checking RPKI status on servers..."
  
  # Create a separator function for cleaner output
  separator() {
    echo -e "\n-------------------------------------------------------------\n"
  }
  
  separator
  echo "PRIMARY SERVER RPKI STATUS (Newark)"
  separator
  
  echo "1. Routinator status (local with ARIN TAL priority):"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show protocols rpki_routinator"
  
  echo "2. ARIN external validator status:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show protocols rpki_arin"
  
  echo "3. RIPE validator status:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show protocols rpki_ripe"
  
  echo "4. Cloudflare validator status:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show protocols rpki_cloudflare"
  
  separator
  echo "IPV6 SERVER RPKI STATUS (Los Angeles)"
  separator
  
  echo "1. Routinator status (local with ARIN TAL priority):"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show protocols rpki_routinator"
  
  echo "2. ARIN external validator status:"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show protocols rpki_arin"
  
  echo "3. RIPE validator status:"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show protocols rpki_ripe"
  
  echo "4. Cloudflare validator status:"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc show protocols rpki_cloudflare"
  
  separator
  echo "ROUTINATOR SERVICE STATUS"
  separator
  
  echo "Primary server Routinator service:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "systemctl status routinator"
  
  echo "IPv6 server Routinator service:"
  ssh $SSH_OPTIONS root@$ipv6_ip "systemctl status routinator"
  
  separator
  echo "RPKI VALIDATION FOR OUR IP RANGES"
  separator
  
  echo "IPv4 Prefix (${OUR_IPV4_BGP_RANGE}) validation status:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc eval 'roa_check(rpki_table, ${OUR_IPV4_BGP_RANGE}, ${OUR_AS})'"
  
  echo "IPv6 Prefix (${OUR_IPV6_BGP_RANGE}) validation status:"
  ssh $SSH_OPTIONS root@$ipv6_ip "birdc eval 'roa_check(rpki_table, ${OUR_IPV6_BGP_RANGE}, ${OUR_AS})'"
  
  separator
  echo "RPKI ROA TABLE STATISTICS"
  separator
  
  echo "ROA table statistics from primary server:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "birdc show route table rpki_table count"
  
  echo "RPKI cache status in Routinator:"
  ssh $SSH_OPTIONS root@$ipv4_primary_ip "routinator vrps stats"
  
  echo "Monitoring complete!"
}

# Function to test failover
test_failover() {
  if [ ! -f "ewr-ipv4-bgp-primary-1c1g_ipv4.txt" ]; then
    echo "Error: Primary server IP file not found. Have you deployed the infrastructure?"
    exit 1
  fi
  
  primary_ip=$(cat ewr-ipv4-bgp-primary-1c1g_ipv4.txt)
  
  echo "Testing failover by stopping BIRD on primary server..."
  
  ssh $SSH_OPTIONS root@$primary_ip "systemctl stop bird"
  
  echo "BIRD stopped on primary server. Traffic should now route to the secondary server."
  echo "To check, try accessing your service on the floating IP or the anycast IP range."
  echo ""
  echo "To restore service on the primary server, run:"
  echo "ssh root@$primary_ip \"systemctl start bird\""
}

# Function to test SSH connectivity
test_ssh() {
  if [ $# -lt 1 ]; then
    echo "Usage: $0 test-ssh <hostname_or_ip> [username]"
    echo "Example: $0 test-ssh 45.32.70.31 root"
    exit 1
  fi
  
  local host=$1
  local user=${2:-root}
  
  echo "Testing SSH connectivity to $user@$host..."
  
  # First try using SSH agent with known working key
  echo "Attempting connection using SSH agent with known working key (nt@infinitum-nihil.com)..."
  ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o IdentityFile=$SSH_KEY_PATH $user@$host echo "Connection successful" 2>/dev/null
  
  # If that fails, try all keys in agent
  if [ $? -ne 0 ]; then
    echo "Trying with all keys in agent..."
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$host echo "Connection successful" 2>/dev/null
  fi
  
  agent_result=$?
  if [ $agent_result -eq 0 ]; then
    echo "✅ Successfully connected to $user@$host using SSH agent."
    return 0
  else
    echo "❌ Could not connect using SSH agent."
  fi
  
  # Then try using the key from .env if it exists
  if [ ! -z "$NT_SSH_PUBLIC_KEY" ]; then
    echo "Trying with key from .env file..."
    
    # Create a temporary private key prompt
    echo "NOTE: To test with the key in .env, I need your private key."
    echo "This is the matching private key for: $(echo "$NT_SSH_PUBLIC_KEY" | cut -d ' ' -f 3)"
    echo "If you don't want to proceed, press Ctrl+C now."
    
    # Create temporary files for key testing
    temp_key_dir=$(mktemp -d)
    temp_pub_key="$temp_key_dir/id_ed25519.pub"
    temp_priv_key="$temp_key_dir/id_ed25519"
    
    # Write public key to temp file
    echo "$NT_SSH_PUBLIC_KEY" > "$temp_pub_key"
    
    # Ask for private key
    echo "Please paste your private key (will not be stored permanently):"
    echo "-----BEGIN OPENSSH PRIVATE KEY-----"
    cat > "$temp_priv_key" << EOT
-----BEGIN OPENSSH PRIVATE KEY-----
EOT
    
    # Read private key content
    while IFS= read -r line; do
      # Stop at end marker
      if [[ $line == "-----END OPENSSH PRIVATE KEY-----" ]]; then
        echo "$line" >> "$temp_priv_key"
        break
      fi
      echo "$line" >> "$temp_priv_key"
    done
    
    echo "-----END OPENSSH PRIVATE KEY-----" >> "$temp_priv_key"
    
    # Set correct permissions
    chmod 600 "$temp_priv_key"
    chmod 644 "$temp_pub_key"
    
    # Test connection with the key
    echo "Testing connection with provided key..."
    ssh -i "$temp_priv_key" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$host echo "Connection successful" 2>/dev/null
    
    key_result=$?
    
    # Clean up
    rm -rf "$temp_key_dir"
    
    if [ $key_result -eq 0 ]; then
      echo "✅ Successfully connected to $user@$host using provided key."
      return 0
    else
      echo "❌ Could not connect using provided key."
    fi
  fi
  
  # Try with ssh-add if available
  if command -v ssh-add &> /dev/null; then
    echo "You can try adding your key to ssh-agent:"
    echo "  ssh-add /path/to/your/private/key"
    echo "Then run this test again."
  fi
  
  echo "SSH connectivity test failed. Please check:"
  echo "1. Your SSH key is authorized on the server"
  echo "2. The server is accessible and running SSH"
  echo "3. No firewall is blocking SSH access"
  
  return 1
}

# Function to clean up temporary files without deleting cloud resources
cleanup_temp_files() {
  log "Cleaning up temporary deployment files..." "INFO"
  
  # Remove instance information files
  find . -name "*_id.txt" -type f -print
  find . -name "*_ipv4.txt" -type f -print
  find . -name "*_ipv6.txt" -type f -print
  find . -name "floating_*.txt" -type f -print
  
  # Actually delete the files if not in dry run mode
  if [ "${DRY_RUN:-false}" != "true" ]; then
    find . -name "*_id.txt" -type f -delete
    find . -name "*_ipv4.txt" -type f -delete
    find . -name "*_ipv6.txt" -type f -delete
    find . -name "floating_*.txt" -type f -delete
    
    # Remove SSH key ID file
    if [ -f "vultr_ssh_key_id.txt" ]; then
      rm -f vultr_ssh_key_id.txt
      log "SSH key ID file deleted" "INFO"
    fi
    
    # Remove generated bird configuration files
    find . -name "*_bird.conf" -type f -delete
    
    # Remove any other temporary files that might cause issues
    find . -name "*_old_id.txt" -type f -delete
    
    log "Temporary files cleanup complete" "INFO"
  else
    log "Dry run mode: Files would be deleted, but no action taken" "INFO"
  fi
}

# Function to clean up resources on failure
cleanup_resources() {
  echo "Starting cleanup of created resources..."
  
  # Clean up all reserved IPs (including attached ones)
  echo "Cleaning up all reserved IPs..."
  cleanup_reserved_ips "true"
  
  # Clean up instances if they were created
  for prefix in "ewr-ipv4-bgp-primary-1c1g" "mia-ipv4-bgp-secondary-1c1g" "ord-ipv4-bgp-tertiary-1c1g" "lax-ipv6-bgp-1c1g"; do
    if [ -f "${prefix}_id.txt" ]; then
      instance_id=$(cat "${prefix}_id.txt")
      echo "Deleting instance $prefix (ID: $instance_id)..."
      
      delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}instances/$instance_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
        
      echo "Instance deletion initiated for $prefix."
      rm -f "${prefix}_id.txt"
      rm -f "${prefix}_ipv4.txt"
      rm -f "${prefix}_ipv6.txt"
    fi
  done
  
  # Clean up floating IPs if they were created
  for region in "${IPV4_REGIONS[@]}" "${IPV6_REGION}"; do
    # Check for IPv4 floating IPs
    if [ -f "floating_ipv4_${region}_id.txt" ]; then
      floating_id=$(cat "floating_ipv4_${region}_id.txt")
      echo "Deleting floating IPv4 in region $region (ID: $floating_id)..."
      
      delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}reserved-ips/$floating_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
        
      echo "Floating IPv4 deletion initiated for region $region."
      rm -f "floating_ipv4_${region}_id.txt"
      rm -f "floating_ipv4_${region}.txt"
    fi
    
    # Check for IPv6 floating IPs
    if [ -f "floating_ipv6_${region}_id.txt" ]; then
      floating_id=$(cat "floating_ipv6_${region}_id.txt")
      echo "Deleting floating IPv6 in region $region (ID: $floating_id)..."
      
      delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}reserved-ips/$floating_id" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
        
      echo "Floating IPv6 deletion initiated for region $region."
      rm -f "floating_ipv6_${region}_id.txt"
      rm -f "floating_ipv6_${region}.txt"
    fi
  done
  
  # Clean up SSH key if it was created
  if [ -f "vultr_ssh_key_id.txt" ]; then
    ssh_key_id=$(cat "vultr_ssh_key_id.txt")
    echo "Deleting SSH key in Vultr (ID: $ssh_key_id)..."
    
    delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}ssh-keys/$ssh_key_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
      
    echo "SSH key deletion initiated."
    rm -f "vultr_ssh_key_id.txt"
  fi
  
  # Also clean up any remaining temp files
  cleanup_temp_files
  
  echo "Cleanup completed."
  echo "You may want to verify in the Vultr control panel that all resources were properly deleted."
  
  # Return failure code to ensure script exits properly after cleanup
  return 1
}

# Function to clean up old birdbgp-losangeles VM
cleanup_old_vm() {
  if [ ! -f "birdbgp-losangeles_old_id.txt" ]; then
    echo "Error: Old VM ID file not found. No old VM to clean up."
    exit 1
  fi
  
  old_vm_id=$(cat birdbgp-losangeles_old_id.txt)
  
  echo "Checking status of old birdbgp-losangeles VM (ID: $old_vm_id)..."
  
  # Get VM status
  vm_info=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$old_vm_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  vm_status=$(echo $vm_info | grep -o '"status":"[^"]*' | cut -d'"' -f4)
  
  echo "Old VM status: $vm_status"
  
  if [ "$vm_status" == "active" ]; then
    echo "WARNING: Old VM is still active. Stopping it first..."
    
    # Stop VM
    stop_response=$(curl -s -X POST "${VULTR_API_ENDPOINT}instances/$old_vm_id/halt" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    echo "Waiting for VM to stop..."
    sleep 30
    
    # Check status again
    vm_info=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances/$old_vm_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    vm_status=$(echo $vm_info | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    if [ "$vm_status" == "active" ]; then
      echo "ERROR: Failed to stop old VM. Please stop it manually and try again."
      echo "Command to stop: curl -X POST \"${VULTR_API_ENDPOINT}instances/$old_vm_id/halt\" -H \"Authorization: Bearer \${VULTR_API_KEY}\""
      exit 1
    fi
  fi
  
  # Confirm deletion
  echo "Are you sure you want to PERMANENTLY DELETE the old birdbgp-losangeles VM?"
  echo "This action CANNOT be undone!"
  read -p "Type 'DELETE' to confirm: " confirm
  
  if [ "$confirm" != "DELETE" ]; then
    echo "Deletion aborted."
    exit 1
  fi
  
  # Delete VM
  echo "Deleting old VM..."
  delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}instances/$old_vm_id" \
    -H "Authorization: Bearer ${VULTR_API_KEY}")
  
  echo "Old VM deletion initiated."
  echo "Please verify in the Vultr control panel that the VM has been deleted."
  
  # Remove ID file
  rm -f "birdbgp-losangeles_old_id.txt"
}

# Function to enable RTBH for specific IPs under attack
apply_rtbh() {
  local server_ip=$1
  local target_ip=$2
  
  echo "Applying RTBH for IP $target_ip via server $server_ip..."
  
  if [[ ! $target_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! $target_ip =~ ^[0-9a-fA-F:]+$ ]]; then
    echo "Error: Invalid IP address format: $target_ip"
    return 1
  fi
  
  # Extract the protocol (IPv4 or IPv6)
  local ip_protocol="ipv4"
  if [[ $target_ip =~ ":" ]]; then
    ip_protocol="ipv6"
  fi
  
  # Determine the appropriate prefix length (Host routes)
  local prefix="/32"
  if [ "$ip_protocol" == "ipv6" ]; then
    prefix="/128"
  fi
  
  # Apply RTBH configuration via SSH
  ssh $SSH_OPTIONS root@$server_ip << EOF
    # Create a temporary script for RTBH configuration
    cat > /tmp/rtbh_config.sh << 'SCRIPT'
#!/bin/bash
# Add specific IP to be blackholed
cat > /etc/bird/rtbh.conf << 'RTBH'
# Remote Triggered Black Hole routes
protocol static rtbh_routes {
  ${ip_protocol};
  route ${target_ip}${prefix} blackhole;
}
RTBH

# Include RTBH file in BIRD config if not already included
grep -q 'include "rtbh.conf";' /etc/bird/bird.conf || sed -i '/# RPKI Configuration/i include "rtbh.conf";\\n' /etc/bird/bird.conf

# Modify the export filter to add the blackhole community if it doesn't exist
if ! grep -q '20473,666' /etc/bird/bird.conf; then
  # Find the position to insert the community
  if grep -q 'export filter' /etc/bird/bird.conf; then
    line_number=\$(grep -n 'bgp_community.add' /etc/bird/bird.conf | head -1 | cut -d':' -f1)
    if [ ! -z "\$line_number" ]; then
      sed -i "\${line_number}i\        # Add blackhole community for RTBH\\n        if (dest = RTD_BLACKHOLE) then bgp_community.add((20473,666));" /etc/bird/bird.conf
    fi
  fi
fi

# Restart BIRD to apply changes
systemctl restart bird
echo "RTBH enabled for ${target_ip}${prefix}"
SCRIPT

    # Make script executable and run it
    chmod +x /tmp/rtbh_config.sh
    /tmp/rtbh_config.sh
    
    # Verify RTBH configuration
    echo "Checking RTBH route status:"
    birdc show route protocol rtbh_routes
EOF

  echo "RTBH configured for $target_ip via $server_ip"
  echo "Traffic to this IP will be dropped at Vultr's edge."
  echo "Warning: This IP is now inaccessible. To restore access, remove the RTBH configuration."
}

# Function to implement ASPA support and protocol configuration
configure_aspa() {
  local server_ip=$1
  
  echo "Configuring ASPA support on server $server_ip..."
  
  ssh $SSH_OPTIONS root@$server_ip << EOF
    # Create ASPA configuration file
    cat > /etc/bird/aspa.conf << 'ASPA'
# ASPA (Autonomous System Provider Authorization) Configuration
# Defines your expected upstreams to prevent route leaks and hijacking

# Import ASPA data from Routinator
# Note: Routinator must be built from source with --features aspa flag
protocol rpki aspa_source {
  table aspa_table;
  remote "localhost" port 8323;
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  aspa4 { table aspa_table; };
  aspa6 { table aspa_table; };
  # Set extended timeouts to account for ASPA processing
  retry keep 900;
  refresh keep 900;
  expire keep 10800;
}

# Authorized providers for our ASN
# This defines the only ASNs that should be seen as upstreams of our ASN
function aspa_check() {
  # Define Vultr ASN as our only authorized upstream
  if (bgp_path.len > 1) then {
    if (bgp_path[1] != 64515) then {
      print "ASPA: Invalid upstream AS for our ASN. Expected 64515 (Vultr), got ", bgp_path[1];
      return false;
    }
  }
  return true;
}

# Enhanced RPKI function that also checks ASPA status
function enhanced_route_security() {
  # First check RPKI
  if (roa_check(rpki_table, net, bgp_path.last) = ROA_INVALID) then {
    print "RPKI: Invalid route: ", net, " ASN: ", bgp_path.last;
    reject;
  }
  
  # Then check ASPA
  if (!aspa_check()) then {
    reject;
  }
  
  # Mark routes with RPKI status in communities
  if (roa_check(rpki_table, net, bgp_path.last) = ROA_VALID) then {
    bgp_community.add((${OUR_AS}, 1001)); # RPKI valid
  } else if (roa_check(rpki_table, net, bgp_path.last) = ROA_UNKNOWN) then {
    bgp_community.add((${OUR_AS}, 1002)); # RPKI unknown
  }
  
  accept;
}
ASPA

    # Include ASPA file in BIRD config
    grep -q 'include "aspa.conf";' /etc/bird/bird.conf || sed -i '/# RPKI Configuration/i include "aspa.conf";\\n' /etc/bird/bird.conf
    
    # Update import filters to use enhanced_route_security instead of rpki_check
    sed -i 's/import where rpki_check()/import where enhanced_route_security()/g' /etc/bird/bird.conf
    
    # Restart BIRD to apply changes
    systemctl restart bird
    
    echo "ASPA support configured. Vultr (AS64515) is now the only authorized upstream."
EOF

  echo "ASPA support configured on server $server_ip"
  echo "The server will now verify that BGP paths only include authorized upstreams."
  echo "This helps prevent route leaks and certain forms of BGP hijacking."
}

# Function to add specific BGP communities to manipulate routing
apply_bgp_community() {
  local server_ip=$1
  local community_type=$2
  local target_as=${3:-0} # Optional target AS
  
  echo "Applying BGP community to server $server_ip: $community_type"
  
  # Build the community string based on the type and target
  local community_cmd=""
  
  case "$community_type" in
    no-advertise)
      if [ "$target_as" -eq 0 ]; then
        # Don't advertise out of AS20473
        community_cmd="bgp_community.add((20473,6000));"
      else
        # Don't advertise to specific AS
        community_cmd="bgp_community.add((64600,$target_as));"
        community_cmd="$community_cmd\nbgp_large_community.add((20473,6000,$target_as));"
      fi
      ;;
    prepend-1x)
      if [ "$target_as" -eq 0 ]; then
        # Prepend 1x to all peers
        community_cmd="bgp_community.add((20473,6001));"
      else
        # Prepend 1x to specific AS
        community_cmd="bgp_community.add((64601,$target_as));"
        community_cmd="$community_cmd\nbgp_large_community.add((20473,6001,$target_as));"
      fi
      ;;
    prepend-2x)
      if [ "$target_as" -eq 0 ]; then
        # Prepend 2x to all peers
        community_cmd="bgp_community.add((20473,6002));"
      else
        # Prepend 2x to specific AS
        community_cmd="bgp_community.add((64602,$target_as));"
        community_cmd="$community_cmd\nbgp_large_community.add((20473,6002,$target_as));"
      fi
      ;;
    prepend-3x)
      if [ "$target_as" -eq 0 ]; then
        # Prepend 3x to all peers
        community_cmd="bgp_community.add((20473,6003));"
      else
        # Prepend 3x to specific AS
        community_cmd="bgp_community.add((64603,$target_as));"
        community_cmd="$community_cmd\nbgp_large_community.add((20473,6003,$target_as));"
      fi
      ;;
    no-ixp)
      # Do not announce to IXP peers
      community_cmd="bgp_community.add((20473,6601));"
      ;;
    ixp-only)
      # Announce to IXP route servers only
      community_cmd="bgp_community.add((20473,6602));"
      ;;
    blackhole)
      # Export blackhole to all peers
      community_cmd="bgp_community.add((20473,666));"
      ;;
    *)
      echo "Unknown community type: $community_type"
      echo "Available types: no-advertise, prepend-1x, prepend-2x, prepend-3x, no-ixp, ixp-only, blackhole"
      return 1
      ;;
  esac
  
  # Update BIRD configuration to add the community
  ssh $SSH_OPTIONS root@$server_ip << EOF
    # Create a temporary file with the community addition
    cat > /tmp/bird_community_update.sh << 'SCRIPT'
#!/bin/bash
# Add community to export filter
sed -i '/export filter {/,/accept;/ s/accept;/# Community added by script\n        $community_cmd\n        accept;/' /etc/bird/bird.conf
# Restart BIRD to apply changes
systemctl restart bird
SCRIPT
    
    # Make it executable and run it
    chmod +x /tmp/bird_community_update.sh
    /tmp/bird_community_update.sh
    
    # Verify the changes
    echo "Checking BGP status after community update:"
    birdc show route all
    birdc show protocols
EOF
  
  echo "BGP community applied successfully to $server_ip"
}

# Parse command line arguments
case "$1" in
  setup)
    setup_env
    ;;
  deploy)
    deploy
    ;;
  monitor)
    monitor
    ;;
  test-failover)
    test_failover
    ;;
  test-ssh)
    if [ $# -lt 2 ]; then
      echo "Usage: $0 test-ssh <hostname_or_ip> [username]"
      echo "Example: $0 test-ssh 45.32.70.31 root"
      exit 1
    fi
    test_ssh "$2" "${3:-root}"
    ;;
  rtbh)
    if [ $# -lt 3 ]; then
      echo "Usage: $0 rtbh <server_ip> <target_ip>"
      echo "Example: $0 rtbh 45.32.70.31 192.0.2.1"
      echo "This will blackhole traffic to the target IP at Vultr's edge using BGP community 20473:666"
      exit 1
    fi
    apply_rtbh "$2" "$3"
    ;;
  aspa)
    if [ $# -lt 2 ]; then
      echo "Usage: $0 aspa <server_ip>"
      echo "Example: $0 aspa 45.32.70.31"
      echo "This will configure ASPA support to allow only Vultr as your upstream"
      exit 1
    fi
    configure_aspa "$2"
    ;;
  community)
    if [ $# -lt 3 ]; then
      echo "Usage: $0 community <server_ip> <community_type> [target_as]"
      echo "Available community types: no-advertise, prepend-1x, prepend-2x, prepend-3x, no-ixp, ixp-only, blackhole"
      exit 1
    fi
    apply_bgp_community "$2" "$3" "${4:-0}"
    ;;
  cleanup-old-vm)
    cleanup_old_vm
    ;;
  cleanup-reserved-ips)
    read -p "Delete ALL reserved IPs (including attached ones)? (y/n, default: n): " delete_all
    if [[ $delete_all =~ ^[Yy]$ ]]; then
      cleanup_reserved_ips "true"  # Delete all IPs, including attached ones
    else
      cleanup_reserved_ips "false"  # Only delete unused IPs
    fi
    ;;
  list-all-resources)
    echo "Listing all BGP Anycast resources in your Vultr account..."
    
    # Check for existing instances with our naming pattern
    echo "Checking for BGP instances..."
    existing_instances_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    # Build instance patterns dynamically from region variables
    # This ensures we find instances in the configured regions, not hardcoded ones
    instance_patterns=()
    instance_patterns+=("${IPV4_REGIONS[0]}-ipv4-bgp-primary")
    instance_patterns+=("${IPV4_REGIONS[1]}-ipv4-bgp-secondary")
    instance_patterns+=("${IPV4_REGIONS[2]}-ipv4-bgp-tertiary")
    instance_patterns+=("${IPV6_REGION}-ipv6-bgp")
    found_instances=false
    
    echo ""
    echo "EXISTING INSTANCES:"
    for pattern in "${instance_patterns[@]}"; do
      if echo "$existing_instances_response" | grep -q "\"label\":\"$pattern"; then
        found_instances=true
        id=$(echo "$existing_instances_response" | grep -o "\"id\":\"[^\"]*\",\"os\":\"[^\"]*\",\"ram\":[^,]*,\"disk\":[^,]*,\"main_ip\":\"[^\"]*\",\"vcpu_count\":[^,]*,\"region\":\"[^\"]*\",\"plan\":\"[^\"]*\",\"date_created\":\"[^\"]*\",\"status\":\"[^\"]*\",\"allowed_bandwidth\":[^,]*,\"netmask_v4\":\"[^\"]*\",\"gateway_v4\":\"[^\"]*\",\"power_status\":\"[^\"]*\",\"server_status\":\"[^\"]*\",\"v6_network\":\"[^\"]*\",\"v6_main_ip\":\"[^\"]*\",\"v6_network_size\":[^,]*,\"label\":\"$pattern[^\"]*\"" | head -1)
        server_id=$(echo "$id" | grep -o "\"id\":\"[^\"]*\"" | cut -d'"' -f4)
        main_ip=$(echo "$id" | grep -o "\"main_ip\":\"[^\"]*\"" | cut -d'"' -f4)
        region=$(echo "$id" | grep -o "\"region\":\"[^\"]*\"" | cut -d'"' -f4)
        label=$(echo "$id" | grep -o "\"label\":\"[^\"]*\"" | cut -d'"' -f4)
        status=$(echo "$id" | grep -o "\"status\":\"[^\"]*\"" | cut -d'"' -f4)
        
        echo "  • $label ($region): $main_ip (Status: $status, ID: $server_id)"
      fi
    done
    
    if [ "$found_instances" = false ]; then
      echo "  None found"
    fi
    
    # Check for reserved IPs
    echo ""
    echo "RESERVED IPs:"
    reserved_ips_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    total_ip_count=$(echo "$reserved_ips_response" | grep -o '"id":"[^"]*"' | wc -l)
    
    if [ "$total_ip_count" -gt 0 ]; then
      echo "$reserved_ips_response" | grep -o '"id":"[^"]*","region":"[^"]*","ip_type":"[^"]*","subnet":"[^"]*","subnet_size":[^,]*,"label":"[^"]*"' | \
      while read -r line; do
        id=$(echo "$line" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
        region=$(echo "$line" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
        ip_type=$(echo "$line" | grep -o '"ip_type":"[^"]*' | cut -d'"' -f4)
        subnet=$(echo "$line" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
        label=$(echo "$line" | grep -o '"label":"[^"]*' | cut -d'"' -f4)
        
        echo "  • ${ip_type}: $subnet (${region}) - $label (ID: $id)"
      done
    else
      echo "  None found"
    fi
    
    echo ""
    echo "OPTIONS:"
    echo "  • To clean up all resources: ./deploy.sh cleanup-all-resources"
    echo "  • To clean up just reserved IPs: ./deploy.sh cleanup-reserved-ips"
    echo "  • To continue deployment: ./deploy.sh deploy"
    ;;
    
  cleanup-all-resources)
    echo "This will clean up ALL BGP Anycast resources (instances and reserved IPs)."
    echo "WARNING: This action cannot be undone!"
    read -p "Are you sure you want to proceed? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
      # Check for existing instances with our naming pattern
      existing_instances_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}instances" \
        -H "Authorization: Bearer ${VULTR_API_KEY}")
      
      # Build instance patterns dynamically from region variables
      # This ensures we find instances in the configured regions, not hardcoded ones
      instance_patterns=()
      instance_patterns+=("${IPV4_REGIONS[0]}-ipv4-bgp-primary")
      instance_patterns+=("${IPV4_REGIONS[1]}-ipv4-bgp-secondary")
      instance_patterns+=("${IPV4_REGIONS[2]}-ipv4-bgp-tertiary")
      instance_patterns+=("${IPV6_REGION}-ipv6-bgp")
      instances_deleted=false
      
      for pattern in "${instance_patterns[@]}"; do
        if echo "$existing_instances_response" | grep -q "\"label\":\"$pattern"; then
          instances_deleted=true
          id=$(echo "$existing_instances_response" | grep -o "\"id\":\"[^\"]*\",\"os\":\"[^\"]*\",\"ram\":[^,]*,\"disk\":[^,]*,\"main_ip\":\"[^\"]*\",\"vcpu_count\":[^,]*,\"region\":\"[^\"]*\",\"plan\":\"[^\"]*\",\"date_created\":\"[^\"]*\",\"status\":\"[^\"]*\",\"allowed_bandwidth\":[^,]*,\"netmask_v4\":\"[^\"]*\",\"gateway_v4\":\"[^\"]*\",\"power_status\":\"[^\"]*\",\"server_status\":\"[^\"]*\",\"v6_network\":\"[^\"]*\",\"v6_main_ip\":\"[^\"]*\",\"v6_network_size\":[^,]*,\"label\":\"$pattern[^\"]*\"" | head -1)
          server_id=$(echo "$id" | grep -o "\"id\":\"[^\"]*\"" | cut -d'"' -f4)
          label=$(echo "$id" | grep -o "\"label\":\"[^\"]*\"" | cut -d'"' -f4)
          
          echo "Deleting instance $label (ID: $server_id)..."
          delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}instances/$server_id" \
            -H "Authorization: Bearer ${VULTR_API_KEY}")
        fi
      done
      
      if [ "$instances_deleted" = false ]; then
        echo "No instances found to delete."
      fi
      
      # Clean up all reserved IPs
      echo "Cleaning up all reserved IPs..."
      cleanup_reserved_ips "true"
      
      # Clean up temporary files
      echo "Cleaning up temporary files..."
      find . -name "*_id.txt" -type f -delete
      find . -name "*_ipv4.txt" -type f -delete
      find . -name "*_ipv6.txt" -type f -delete
      find . -name "floating_*.txt" -type f -delete
      find . -name "*_bird.conf" -type f -delete
      
      echo "All resources cleaned up successfully."
    else
      echo "Cleanup aborted."
    fi
    ;;
    
  list-regions)
    echo "Listing available Vultr regions for deployment..."
    echo "You can configure these regions in your .env file by setting:"
    echo "  IPV4_REGION_PRIMARY=xxx      # Primary IPv4 BGP server (default: ewr)"
    echo "  IPV4_REGION_SECONDARY=xxx    # Secondary IPv4 BGP server (default: mia)"
    echo "  IPV4_REGION_TERTIARY=xxx     # Tertiary IPv4 BGP server (default: ord)"
    echo "  IPV6_REGION=xxx              # IPv6 BGP server (default: lax)"
    echo ""
    
    regions_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}regions" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    echo "┌─────────┬──────────────────┬─────────────┬─────────────┬────────────────┐"
    echo "│ Region  │ City             │ Country     │ Continent   │ Role           │"
    echo "├─────────┼──────────────────┼─────────────┼─────────────┼────────────────┤"
    echo "│ Note: * │ indicates region │ is currently│ configured  │                │"
    echo "├─────────┼──────────────────┼─────────────┼─────────────┼────────────────┤"
    
    echo "$regions_response" | grep -o '"id":"[^"]*","city":"[^"]*","country":"[^"]*","continent":"[^"]*"' | \
    while read -r line; do
      id=$(echo "$line" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      city=$(echo "$line" | grep -o '"city":"[^"]*' | cut -d'"' -f4)
      country=$(echo "$line" | grep -o '"country":"[^"]*' | cut -d'"' -f4)
      continent=$(echo "$line" | grep -o '"continent":"[^"]*' | cut -d'"' -f4)
      
      # Highlight currently configured regions
      marker=""
      role=""
      if [ "$id" = "$IPV4_REGION_PRIMARY" ]; then
        marker="*"
        role="Primary IPv4"
      elif [ "$id" = "$IPV4_REGION_SECONDARY" ]; then
        marker="*"
        role="Secondary IPv4"
      elif [ "$id" = "$IPV4_REGION_TERTIARY" ]; then
        marker="*"
        role="Tertiary IPv4"
      elif [ "$id" = "$IPV6_REGION" ]; then
        marker="*"
        role="IPv6"
      fi
      
      # Display table row
      printf "│ %-7s │ %-16s │ %-11s │ %-11s │ %-14s │\n" "$id$marker" "$city" "$country" "$continent" "$role"
    done
    
    echo "└─────────┴──────────────────┴─────────────┴─────────────┴────────────────┘"
    echo ""
    echo "To change regions, edit your .env file and set the following variables:"
    echo "  IPV4_REGION_PRIMARY=region_code      # For primary IPv4 server"
    echo "  IPV4_REGION_SECONDARY=region_code    # For secondary IPv4 server"
    echo "  IPV4_REGION_TERTIARY=region_code     # For tertiary IPv4 server"
    echo "  IPV6_REGION=region_code              # For IPv6 server"
    echo ""
    echo "Example:"
    echo "  IPV4_REGION_PRIMARY=ewr              # Newark"
    echo "  IPV4_REGION_SECONDARY=mia            # Miami"
    echo "  IPV4_REGION_TERTIARY=ord             # Chicago"
    echo "  IPV6_REGION=lax                      # Los Angeles"
    ;;
    
  list-reserved-ips)
    echo "Listing all reserved IPs in your Vultr account..."
    reserved_ips_response=$(curl -s -X GET "${VULTR_API_ENDPOINT}reserved-ips" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    total_count=$(echo "$reserved_ips_response" | grep -o '"id":"[^"]*"' | wc -l)
    echo "Found $total_count total reserved IPs in your account:"
    echo ""
    
    # Extract and display the IPs in a readable format
    echo "$reserved_ips_response" | grep -o '"id":"[^"]*","region":"[^"]*","ip_type":"[^"]*","subnet":"[^"]*","subnet_size":[^,]*,"label":"[^"]*"' | \
    while read -r line; do
      id=$(echo "$line" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      region=$(echo "$line" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
      ip_type=$(echo "$line" | grep -o '"ip_type":"[^"]*' | cut -d'"' -f4)
      subnet=$(echo "$line" | grep -o '"subnet":"[^"]*' | cut -d'"' -f4)
      label=$(echo "$line" | grep -o '"label":"[^"]*' | cut -d'"' -f4)
      instance_id=$(echo "$line" | grep -o '"instance_id":"[^"]*' | cut -d'"' -f4 || echo "none")
      
      if [ -z "$instance_id" ] || [ "$instance_id" = "none" ]; then
        status="UNATTACHED"
      else
        status="Attached to instance $instance_id"
      fi
      
      echo "ID: $id"
      echo "  Region: $region"
      echo "  IP Type: $ip_type"
      echo "  Subnet: $subnet"
      echo "  Label: $label"
      echo "  Status: $status"
      echo ""
    done
    ;;
  force-delete-ip)
    if [ $# -lt 2 ]; then
      echo "Usage: $0 force-delete-ip <reserved_ip_id>"
      echo "Example: $0 force-delete-ip 52b64e73-f454-4f2e-b84f-b6004e1ad4bf"
      echo "Use the list-reserved-ips command to get the ID of the reserved IP you want to delete"
      exit 1
    fi
    
    ip_id="$2"
    echo "Forcibly deleting reserved IP with ID: $ip_id..."
    
    # First try to detach if it's attached
    curl -s -X POST "${VULTR_API_ENDPOINT}reserved-ips/$ip_id/detach" \
      -H "Authorization: Bearer ${VULTR_API_KEY}"
    
    # Wait a moment for detachment to complete
    sleep 5
    
    # Then delete it
    delete_response=$(curl -s -X DELETE "${VULTR_API_ENDPOINT}reserved-ips/$ip_id" \
      -H "Authorization: Bearer ${VULTR_API_KEY}")
    
    if [ -z "$delete_response" ]; then
      echo "Successfully deleted reserved IP with ID: $ip_id"
    else
      echo "Error deleting reserved IP: $delete_response"
    fi
    ;;
  cleanup)
    echo "This will clean up ALL resources created by this script."
    echo "WARNING: This action cannot be undone!"
    read -p "Are you sure you want to proceed? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
      cleanup_resources
    else
      echo "Cleanup aborted."
    fi
    ;;
  cleanup-temp-files)
    echo "This will clean up temporary files created during deployment without removing cloud resources."
    read -p "Continue? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
      cleanup_temp_files
    else
      echo "Temporary files cleanup aborted."
    fi
    ;;
  *)
    echo "Usage: $0 {setup|deploy|monitor|test-failover|test-ssh|rtbh|aspa|community|list-regions|list-all-resources|cleanup-all-resources|cleanup-old-vm|cleanup-reserved-ips|list-reserved-ips|force-delete-ip|cleanup|cleanup-temp-files}"
    echo "       $0 test-ssh <hostname_or_ip> [username]"
    echo "       $0 rtbh <server_ip> <target_ip>"
    echo "       $0 aspa <server_ip>"
    echo "       $0 community <server_ip> <community_type> [target_as]"
    echo ""
    echo "Commands:"
    echo "  setup               - Set up or reconfigure .env file interactively"
    echo "  deploy              - Deploy the BGP Anycast infrastructure"
    echo "  monitor             - Monitor the status of the BGP Anycast infrastructure"
    echo "  test-failover       - Test failover by stopping BIRD on the primary server"
    echo "  test-ssh            - Test SSH connectivity to a server"
    echo "  rtbh                - Configure Remote Triggered Black Hole for DDoS mitigation"
    echo "  aspa                - Configure ASPA validation for enhanced security"
    echo "  community           - Apply BGP communities to manipulate routing"
    echo "  list-regions         - List available Vultr regions for deployment configuration"
    echo "  list-all-resources   - List all BGP Anycast resources (instances and reserved IPs)"
    echo "  cleanup-all-resources - Clean up all BGP Anycast resources (instances and reserved IPs)"
    echo "  cleanup-old-vm      - Clean up the old birdbgp-losangeles VM after successful deployment"
    echo "  cleanup-reserved-ips - Clean up unused floating/reserved IPs to stay within account limits"
    echo "  list-reserved-ips    - List all reserved IPs in your Vultr account"
    echo "  force-delete-ip      - Forcibly delete a specific reserved IP by ID"
    echo "  cleanup             - Clean up ALL resources created by this script"
    echo "  cleanup-temp-files   - Clean up temporary files without removing cloud resources"
    exit 1
    ;;
esac

exit 0