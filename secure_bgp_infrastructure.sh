#!/bin/bash
# BGP Anycast Infrastructure Security Hardening Script
# This script implements comprehensive security measures for BGP infrastructure

# Exit on any error
set -e

# Log file setup
LOG_FILE="security_hardening_$(date +%Y%m%d_%H%M%S).log"
echo "Starting security hardening at $(date)" > "$LOG_FILE"

# Log function
log() {
  local message="$1"
  local level="${2:-INFO}"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  
  echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
  echo "[$level] $message"
}

# Function to check if environment variables are set
check_env_vars() {
  log "Checking required environment variables" "INFO"
  
  local required_vars=("OUR_AS" "OUR_IPV4_BGP_RANGE" "OUR_IPV6_BGP_RANGE" "VULTR_BGP_PASSWORD" "SSH_KEY_PATH")
  local missing_vars=false
  
  for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      log "Missing required environment variable: $var" "ERROR"
      missing_vars=true
    fi
  done
  
  if [ "$missing_vars" = true ]; then
    log "Please set all required environment variables in .env file" "ERROR"
    exit 1
  fi
  
  log "All required environment variables are set" "INFO"
}

# Function to secure file permissions
secure_file_permissions() {
  local config_dir="$1"
  
  log "Securing file permissions for configuration files" "INFO"
  
  # Secure .env file if it exists
  if [ -f ".env" ]; then
    chmod 600 .env
    log "Secured .env file permissions" "INFO"
  fi
  
  # Secure SSH private key
  if [ -f "$SSH_KEY_PATH" ]; then
    chmod 600 "$SSH_KEY_PATH"
    log "Secured SSH private key permissions" "INFO"
  fi
  
  # Secure configuration directory
  if [ -d "$config_dir" ]; then
    find "$config_dir" -type f -name "*.json" -exec chmod 640 {} \;
    find "$config_dir" -type f -name "*.sh" -exec chmod 750 {} \;
    log "Secured configuration directory permissions" "INFO"
  fi
}

# Function to secure a remote server
secure_server() {
  local server_ip="$1"
  local ssh_key="$2"
  local server_name="$3"
  
  log "Securing server $server_name ($server_ip)" "INFO"
  
  # Create a temporary security script
  local temp_script=$(mktemp)
  
  cat > "$temp_script" << 'EOF'
#!/bin/bash

# Exit on any error
set -e

# Make script output visible
echo "Starting security hardening process..."

# 1. Update system packages
echo "Updating system packages..."
apt-get update
apt-get upgrade -y

# 2. Configure automatic security updates
echo "Configuring automatic security updates..."
apt-get install -y unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'APTEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APTEOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTOEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOEOF

# 3. Configure SSH hardening
echo "Configuring SSH hardening..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
cat > /etc/ssh/sshd_config << 'SSHEOF'
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

SyslogFacility AUTH
LogLevel VERBOSE

LoginGraceTime 30
PermitRootLogin prohibit-password
StrictModes yes
MaxAuthTries 4
MaxSessions 10

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PrintMotd no

ClientAliveInterval 300
ClientAliveCountMax 2

AcceptEnv LANG LC_*

Subsystem sftp /usr/lib/openssh/sftp-server
SF_OPTS="-f AUTHPRIV -l INFO"
SSHEOF

# 4. Setup Firewall (iptables) for IPv4
echo "Configuring IPv4 firewall rules..."
apt-get install -y iptables-persistent

# Flush existing rules
iptables -F
iptables -X

# Set default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow local traffic
iptables -A INPUT -i lo -j ACCEPT

# Allow SSH with rate limiting
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# Allow BGP only from Vultr BGP server
iptables -A INPUT -p tcp --dport 179 -s 169.254.169.254 -j ACCEPT

# Allow ICMP for network diagnostics
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# Allow DNS
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 53 -j ACCEPT

# Log dropped packets
iptables -A INPUT -j LOG --log-prefix "[IPTABLES DROP] " --log-level 4

# Save IPv4 rules
netfilter-persistent save

# 5. Setup Firewall (ip6tables) for IPv6
echo "Configuring IPv6 firewall rules..."

# Flush existing rules
ip6tables -F
ip6tables -X

# Set default policies
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

# Allow established connections
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow local traffic
ip6tables -A INPUT -i lo -j ACCEPT

# Allow SSH with rate limiting
ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set
ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# Allow BGP only from Vultr IPv6 BGP server
ip6tables -A INPUT -p tcp --dport 179 -s 2001:19f0:ffff::1 -j ACCEPT

# Allow ICMPv6 (required for IPv6 operation)
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

# Allow DHCPv6 client traffic
ip6tables -A INPUT -p udp --dport 546 -j ACCEPT

# Allow DNS
ip6tables -A INPUT -p udp --dport 53 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 53 -j ACCEPT

# Log dropped packets
ip6tables -A INPUT -j LOG --log-prefix "[IP6TABLES DROP] " --log-level 4

# Save IPv6 rules
netfilter-persistent save

# 6. Configure system hardening (sysctl)
echo "Configuring kernel security parameters..."
cat > /etc/sysctl.d/99-security.conf << 'SYSCTLEOF'
# IPv4 security settings
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0

# IPv6 security settings
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_source_route=0
net.ipv6.conf.default.accept_source_route=0

# TCP hardening
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=2048
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=5

# Additional kernel hardening
kernel.randomize_va_space=2
kernel.kptr_restrict=1
kernel.dmesg_restrict=1
SYSCTLEOF

# Apply sysctl settings
sysctl -p /etc/sysctl.d/99-security.conf

# 7. Install and configure Fail2ban
echo "Installing and configuring Fail2ban..."
apt-get install -y fail2ban
cat > /etc/fail2ban/jail.local << 'FAIL2BANEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
FAIL2BANEOF

systemctl enable fail2ban
systemctl restart fail2ban

# 8. Install and configure CrowdSec
echo "Installing and configuring CrowdSec..."
curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
apt-get install -y crowdsec
cscli collections install crowdsecurity/linux
cscli collections install crowdsecurity/sshd
cscli collections install crowdsecurity/iptables

systemctl enable crowdsec
systemctl restart crowdsec

# 9. Install auditd for system auditing
echo "Installing and configuring audit system..."
apt-get install -y auditd

# Basic audit rules
cat > /etc/audit/rules.d/security.rules << 'AUDITEOF'
# Log authentication events
-w /var/log/auth.log -p wa -k authentication
-w /etc/pam.d/ -p wa -k pam
-w /etc/nsswitch.conf -p wa -k nsswitch
-w /etc/ssh/sshd_config -p wa -k sshd_config

# Log network configuration changes
-w /etc/network/ -p wa -k network
-w /etc/hosts -p wa -k hosts

# Monitor user/group changes
-w /etc/passwd -p wa -k passwd
-w /etc/shadow -p wa -k shadow
-w /etc/group -p wa -k group

# Monitor sudoers
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Monitor BGP configuration
-w /etc/bird/ -p wa -k bird_config
-w /var/run/bird/ -p wa -k bird_socket
AUDITEOF

systemctl enable auditd
systemctl restart auditd

# 10. BIRD RPKI Configuration (if BIRD is installed)
if [ -d "/etc/bird" ]; then
  echo "Configuring BIRD for RPKI validation..."
  
  # Install necessary packages for Routinator
  apt-get install -y build-essential libssl-dev pkg-config curl clang
  
  # Install Rust (needed for Routinator)
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source $HOME/.cargo/env
  
  # Install Routinator
  cargo install routinator
  
  # Initialize and update RPKI cache
  routinator init --accept-arin-rpa
  routinator vrps
  
  # Configure Routinator as a service
  cat > /etc/systemd/system/routinator.service << 'ROUTEOF'
[Unit]
Description=Routinator RPKI Validator
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/.cargo/bin/routinator server --rtr 127.0.0.1:3323 --http 127.0.0.1:9556
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
ROUTEOF

  systemctl enable routinator
  systemctl start routinator
  
  # Configure BIRD to use RPKI
  if [ -f "/etc/bird/bird.conf" ]; then
    # Backup original config
    cp /etc/bird/bird.conf /etc/bird/bird.conf.bak
    
    # Check if RPKI configuration exists, add if not
    if ! grep -q "roa4 table" /etc/bird/bird.conf; then
      cat >> /etc/bird/bird.conf << 'BIRDEOF'

# RPKI integration
roa4 table r4;
roa6 table r6;

protocol rpki {
    roa4 { table r4; };
    roa6 { table r6; };
    transport tcp {
        # Local Routinator
        remote 127.0.0.1:3323;
        # ARIN
        remote rtr.arin.net:323 {
            priority 10;
        };
        # RIPE
        remote rpki-validator.ripe.net:8323 {
            priority 20;
        };
    };
}

function set_rpki_vars(int peeras) {
    if (roa_check(r4, net, peeras) = ROA_VALID) then {
        bgp_community.add((OUR_ASN, 1001)); # RPKI valid
    }
    else if (roa_check(r4, net, peeras) = ROA_UNKNOWN) then {
        bgp_community.add((OUR_ASN, 1002)); # RPKI unknown
    }
    else if (roa_check(r4, net, peeras) = ROA_INVALID) then {
        bgp_community.add((OUR_ASN, 1000)); # RPKI invalid
        reject;
    }
}
BIRDEOF
    fi
    
    # Restart BIRD to apply changes
    systemctl restart bird
  fi
fi

# 11. Secure BIRD socket permissions
if [ -d "/var/run/bird" ]; then
  echo "Securing BIRD socket permissions..."
  chown -R root:root /var/run/bird
  chmod 750 /var/run/bird
  chmod 640 /var/run/bird/bird.ctl
fi

# 12. Implement log rotation for all logs
echo "Configuring log rotation..."
apt-get install -y logrotate

cat > /etc/logrotate.d/security << 'LOGROTEOF'
/var/log/auth.log
/var/log/fail2ban.log
/var/log/crowdsec.log
/var/log/bird/*.log
{
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        /etc/init.d/rsyslog rotate > /dev/null
    endscript
}
LOGROTEOF

# 13. Final system checks
echo "Performing final security checks..."

# Check for running services
echo "Running services:"
netstat -tulpn

# Check firewall rules
echo "\nIPv4 firewall rules:"
iptables -L -v

echo "\nIPv6 firewall rules:"
ip6tables -L -v

# Check fail2ban status
echo "\nFail2ban status:"
fail2ban-client status

# Check for user accounts with empty passwords
echo "\nChecking for user accounts with empty passwords:"
awk -F: '($2 == "" ) { print $1 }' /etc/shadow

# Check for SUID/SGID files
echo "\nChecking for unusual SUID/SGID files:"
find / -type f \( -perm -4000 -o -perm -2000 \) -exec ls -la {} \; 2>/dev/null | grep -v -E "/bin/|/sbin/|/usr/bin/|/usr/sbin/|/usr/local/bin/|/usr/local/sbin/"

echo "\nSecurity hardening completed successfully!"
EOF

  # Make the script executable
  chmod +x "$temp_script"
  
  # Copy the script to the server and execute it
  log "Copying security script to $server_name" "INFO"
  scp -i "$ssh_key" -o StrictHostKeyChecking=yes "$temp_script" "root@$server_ip:/tmp/security_hardening.sh"
  
  log "Executing security script on $server_name" "INFO"
  ssh -i "$ssh_key" -o StrictHostKeyChecking=yes "root@$server_ip" "bash /tmp/security_hardening.sh > /root/security_hardening_output.log 2>&1"
  
  # Verify security hardening was successful
  log "Verifying security hardening on $server_name" "INFO"
  ssh -i "$ssh_key" -o StrictHostKeyChecking=yes "root@$server_ip" "systemctl is-active fail2ban && systemctl is-active crowdsec && iptables -L | grep DROP"
  
  if [ $? -eq 0 ]; then
    log "Security hardening successful on $server_name" "INFO"
  else
    log "Security hardening verification failed on $server_name" "ERROR"
  fi
  
  # Remove the temporary script
  rm -f "$temp_script"
}

# Function to get server IPs from config
get_server_ips() {
  local config_file="$1"
  local server_ips=()
  
  if [ -f "$config_file" ]; then
    # Extract IPv4 addresses from the JSON config
    ipv4_addresses=$(grep -o '"address": "[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+"' "$config_file" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+')
    
    # Add IPv4 addresses to array
    for ip in $ipv4_addresses; do
      server_ips+=("$ip")
    done
  else
    log "Configuration file not found: $config_file" "ERROR"
    exit 1
  fi
  
  echo "${server_ips[@]}"
}

# Function to get server names from config
get_server_names() {
  local config_file="$1"
  local server_names=()
  
  if [ -f "$config_file" ]; then
    # Extract region and location data from the JSON config
    regions=$(grep -o '"[a-z]\+-[a-z]\+": {' "$config_file" | sed 's/": {//g' | sed 's/"//g')
    locations=$(grep -o '"[a-z]\+": {' "$config_file" | sed 's/": {//g' | sed 's/"//g' | grep -v "ipv4\|ipv6\|authentication\|metadata")
    
    # Combine regions and locations
    for region in $regions; do
      for location in $locations; do
        server_names+=("$region-$location")
      done
    done
  else
    log "Configuration file not found: $config_file" "ERROR"
    exit 1
  fi
  
  echo "${server_names[@]}"
}

# Main function
main() {
  log "Starting BGP Anycast Infrastructure security hardening" "INFO"
  
  # Check if running as root
  if [ "$(id -u)" -ne 0 ]; then
    log "This script must be run as root" "ERROR"
    exit 1
  fi
  
  # Load environment variables
  if [ -f ".env" ]; then
    source .env
    log "Loaded environment variables from .env" "INFO"
  else
    log ".env file not found. Creating from template..." "WARN"
    if [ -f ".env.template" ]; then
      cp .env.template .env
      log "Created .env from template. Please edit with your actual values before continuing." "INFO"
      exit 0
    else
      log ".env.template file not found. Please create .env with required variables." "ERROR"
      exit 1
    fi
  fi
  
  # Check required environment variables
  check_env_vars
  
  # Secure local file permissions
  secure_file_permissions "config_files"
  
  # Get server IPs and names from config
  CONFIG_FILE="config_files/config.json"
  server_ips=($(get_server_ips "$CONFIG_FILE"))
  server_names=($(get_server_names "$CONFIG_FILE"))
  
  # Verify SSH key exists and has correct permissions
  if [ ! -f "$SSH_KEY_PATH" ]; then
    log "SSH key not found at $SSH_KEY_PATH" "ERROR"
    exit 1
  fi
  
  chmod 600 "$SSH_KEY_PATH"
  
  # Apply security hardening to each server
  for i in "${!server_ips[@]}"; do
    secure_server "${server_ips[$i]}" "$SSH_KEY_PATH" "${server_names[$i]}"
  done
  
  log "BGP Anycast Infrastructure security hardening completed successfully" "INFO"
}

# Run main function
main
