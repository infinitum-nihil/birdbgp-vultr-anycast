# Security Guidelines for BGP Anycast Infrastructure

This document outlines security best practices, policies, and procedures for maintaining our BGP Anycast infrastructure.

## Table of Contents

1. [Security Best Practices](#security-best-practices)
2. [Credential Management](#credential-management)
3. [Vulnerability Reporting](#vulnerability-reporting)
4. [Security Incident Response](#security-incident-response)
5. [System Hardening Guidelines](#system-hardening-guidelines)
6. [RPKI Configuration](#rpki-configuration)
7. [Network Security](#network-security)
8. [SSH Access Security](#ssh-access-security)
9. [Monitoring and Alerting](#monitoring-and-alerting)
10. [Compliance and Auditing](#compliance-and-auditing)

## Security Best Practices

### General Principles

- Follow the principle of least privilege
- Implement defense in depth
- Keep all systems updated
- Regularly audit and review security configurations
- Minimize attack surface
- Encrypt sensitive data at rest and in transit

### BGP-Specific Security

- Always use BGP authentication
- Implement RPKI validation for all BGP sessions
- Configure proper prefix filtering
- Implement maximum prefix limits
- Use path prepending cautiously and consistently
- Monitor for unexpected route announcements

## Credential Management

### API Keys and Secrets

- **NEVER** commit credentials to the git repository
- Use `.env.template` as a guide and create `.env` locally
- Rotate API keys and credentials at least quarterly
- Use a secure secrets management system when possible
- Implement the principle of least privilege for all API keys

### BGP Passwords

- Use strong, randomly generated passwords (minimum 16 characters)
- Store passwords securely using environment variables or a secrets manager
- Rotate BGP passwords periodically (at least every 90 days)
- Use different passwords for different BGP sessions

### SSH Keys

- Use ED25519 or RSA keys with at least 4096 bits
- Protect private keys with strong passphrases
- Store private keys securely with appropriate file permissions (600)
- Rotate SSH keys annually or when team members leave

## Vulnerability Reporting

### Internal Reporting Process

1. Document the vulnerability with detailed information
2. Assign a severity level using the CVSS scoring system
3. Report to the security team via secure channels
4. Do not discuss vulnerabilities on public channels

### External Reporting Process

If you discover a security vulnerability, please report it by sending an email to `security@your-organization.com`. Please include:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested mitigations

We commit to acknowledging your report within 24 hours and providing regular updates on our progress.

## Security Incident Response

### Incident Definitions

- **Level 1 (Low)**: Single server affected, no service disruption
- **Level 2 (Medium)**: Multiple servers affected, minor service disruption
- **Level 3 (High)**: Infrastructure compromise, major service disruption
- **Level 4 (Critical)**: BGP hijacking, complete service outage, data breach

### Response Procedures

1. **Identification**: Detect and confirm the security incident
2. **Containment**: Isolate affected systems to prevent spread
3. **Eradication**: Remove the threat from all systems
4. **Recovery**: Restore systems to normal operation
5. **Post-Incident Analysis**: Review the incident and improve security

### BGP-Specific Incidents

#### Route Hijacking Response

1. Verify legitimate ownership of prefixes
2. Contact upstream providers to filter illegitimate announcements
3. Increase the specificity of your announcements (announce more specific prefixes)
4. Verify and correct any RPKI misconfigurations

## System Hardening Guidelines

### Operating System Hardening

- Keep systems updated with security patches
- Remove unnecessary packages and services
- Configure automatic security updates
- Implement a host-based firewall
- Enable process accounting and auditing

### Kernel Hardening

Implement the following sysctl settings:

```bash
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

# IPv6 security settings
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# TCP hardening
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=2048
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=5
```

### File System Security

- Set appropriate permissions on configuration files (600 or 640)
- Set appropriate permissions on log files (640 or 644)
- Set appropriate permissions on private keys (600)
- Regularly audit file permissions

## RPKI Configuration

### RPKI Validator Setup

1. Install and configure Routinator or similar RPKI validator
2. Configure BIRD to use the RPKI validator
3. Set up fallback validators for redundancy
4. Monitor RPKI validation status

### RPKI Policy Implementation

- Tag routes with RPKI validation state
- Configure routing policy based on RPKI validation
- Monitor for RPKI-related issues
- Regularly update RPKI configuration

### RPKI ROA Management

- Create ROAs for all announced prefixes
- Keep ROAs updated when prefix assignments change
- Use appropriate maximum prefix length
- Monitor ROA status

## Network Security

### Firewall Configuration

#### IPv4 Firewall Rules

```bash
# Base rules
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

# Allow ICMPv4 for network diagnostics
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
```

#### IPv6 Firewall Rules

```bash
# Base rules
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
```

### DDoS Mitigation

- Implement Remote Triggered Black Hole (RTBH) capability
- Configure BGP flowspec when available
- Implement traffic filtering at the edge
- Use Vultr's DDoS protection services

## SSH Access Security

### SSH Server Configuration

Recommended settings for `/etc/ssh/sshd_config`:

```
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

### SSH Client Configuration

Recommended settings for SSH client usage:

```
Host *
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts
    ServerAliveInterval 60
    IdentitiesOnly yes
    HashKnownHosts yes
```

## Monitoring and Alerting

### Security Monitoring

- Implement log monitoring and analysis
- Configure alerts for security events
- Monitor for unauthorized login attempts
- Monitor for unexpected BGP announcements
- Monitor for RPKI validation failures

### BGP Session Monitoring

- Monitor BGP session state
- Monitor for route flaps
- Monitor for unexpected prefix announcements
- Monitor for RPKI validation status changes

## Compliance and Auditing

### Regular Security Audits

- Perform quarterly security reviews
- Audit firewall rules
- Audit RPKI configuration
- Audit SSH access and keys
- Review BGP peering relationships

### Documentation Requirements

- Maintain up-to-date network diagrams
- Document BGP peering relationships
- Document firewall rules
- Document RPKI configuration
- Document incident response procedures

---

## Appendix A: Recommended Security Tools

- **CrowdSec**: Collaborative security platform
- **Fail2ban**: Intrusion prevention system
- **Routinator**: RPKI validator
- **Lynis**: Security auditing tool
- **Auditd**: Linux auditing system

## Appendix B: Security Checklists

### New Deployment Checklist

- [ ] Configure firewall rules
- [ ] Configure SSH hardening
- [ ] Configure automatic security updates
- [ ] Configure RPKI validation
- [ ] Configure BGP authentication
- [ ] Configure log monitoring
- [ ] Configure security monitoring
- [ ] Create ROAs for announced prefixes
- [ ] Document network topology

### Credential Rotation Checklist

- [ ] Rotate API keys
- [ ] Rotate BGP passwords
- [ ] Rotate SSH keys
- [ ] Update documentation
- [ ] Test all systems after rotation
- [ ] Remove old credentials
