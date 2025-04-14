# Security Architecture for BGP Anycast Infrastructure

This document outlines the comprehensive security measures implemented in our BGP Anycast infrastructure deployment on Vultr.

## Overview

The BGP Anycast infrastructure is protected by multiple layers of security:

1. **Host-based Security**
   - CrowdSec intrusion detection and prevention
   - Fail2ban for brute force protection
   - Iptables firewall with strict defaults
   - Sysctl kernel hardening
   - SSH hardening
   - Automatic security updates

2. **BGP Security**
   - RPKI validation with multiple fallbacks
   - BGP route filtering
   - Protocol-level password authentication
   - Redundant validator chain

## Host Security Components

### CrowdSec

[CrowdSec](https://crowdsec.net/) is a modern security tool that analyzes server logs to detect and block malicious activity:

- Detects intrusion attempts, brute force attacks, and other security threats
- Uses collective intelligence from the CrowdSec community
- Automatically bans malicious IP addresses
- Specifically configured to monitor:
  - System logs (`/var/log/syslog`)
  - Authentication logs (`/var/log/auth.log`)
  - BIRD BGP logs (via syslog)

### Fail2ban

Fail2ban provides an additional layer of protection:

- Focuses on preventing brute force attacks
- Scans log files for too many failed login attempts
- Automatically creates firewall rules to block suspicious IPs
- Works alongside CrowdSec as a secondary defense

### Firewall (iptables/ip6tables)

A strict firewall policy restricts access to servers:

#### IPv4 Rules
- DROP policy on INPUT and FORWARD chains
- ACCEPT only on necessary services:
  - SSH (port 22) with rate limiting
  - BGP (port 179) from Vultr's BGP server only
  - RPKI validators (RTR protocol)
  - ICMP for network diagnostics
  - Basic services (DNS)
- All other traffic is blocked and logged

#### IPv6 Rules
- Similar DROP policy on INPUT and FORWARD chains
- Special IPv6-specific rules:
  - ICMPv6 allowed (required for IPv6 operation)
  - DHCPv6 client traffic allowed
  - BGP allowed from Vultr's IPv6 BGP server (2001:19f0:ffff::1)

### System Hardening (sysctl)

Kernel parameters are tuned for security:

#### IPv4 Security
- Spoofing protection (rp_filter)
- Protection against ICMP broadcast attacks
- Disabled source routing
- Protections against SYN flood attacks
- TCP/IP stack hardening

#### IPv6 Security
- Disabled source routing
- Disabled router advertisements
- Blocked redirects

### SSH Hardening

SSH configuration is hardened:

- Root login restricted to key-based authentication only
- Password authentication disabled
- X11 forwarding disabled
- Login attempts limited
- Connection timeout reduced

### Automatic Security Updates

Servers automatically install security updates:

- Configured via apt's unattended-upgrades
- Focus on security patches only
- Configured not to reboot automatically
- Removes unused dependencies and kernels

## BGP Security Components

### RPKI Validation

Our BGP infrastructure uses Resource Public Key Infrastructure (RPKI) validation to prevent route hijacking:

1. **Validation Chain:**
   - Local Routinator as primary validator (prioritizing ARIN TAL)
   - ARIN's RTR service as first external backup
   - RIPE NCC Validator as second external backup
   - Cloudflare's RPKI validator as final backup

2. **Route Coloring:**
   - Routes are tagged with BGP communities based on RPKI status
   - ${OUR_AS}:1001 for valid routes
   - ${OUR_AS}:1002 for unknown routes
   - ${OUR_AS}:1000 for invalid routes (before rejection)

3. **Validation Policy:**
   - Invalid routes are rejected
   - Unknown routes are accepted (permissive mode)
   - Valid routes are accepted and prioritized

### BGP Authentication

BGP sessions with Vultr are authenticated:

- Password authentication using a strong password stored in .env
- Multihop BGP configuration for added security
- Static routes to Vultr's BGP endpoints

## Monitoring and Management

Security events are logged and can be monitored:

- CrowdSec dashboard and alerts
- Fail2ban logs
- Firewall logs
- BGP session logs
- BIRD logs with RPKI validation outcomes

## Best Practices

1. **Regular Updates:**
   - Keep BIRD and OS updated for security patches
   - Regularly update RPKI validators

2. **Credential Management:**
   - Rotate BGP passwords periodically
   - Use secure key-based authentication for SSH access
   - Consider implementing a secrets management solution

3. **Monitoring:**
   - Implement monitoring for failed login attempts
   - Watch for BGP session flaps
   - Monitor RPKI validation failures

4. **Regular Audits:**
   - Periodically review iptables rules
   - Check SSH access logs
   - Verify CrowdSec and Fail2ban are functioning correctly

## Security Incident Response

In the event of a security incident:

1. **BGP Route Hijacking:**
   - Verify RPKI validation is functioning properly
   - Check ROA status for your prefixes
   - Contact Vultr support if needed

2. **Server Compromise:**
   - Isolate affected server
   - Review logs to determine entry point
   - Rebuild server from scratch
   - Rotate credentials
   - Re-establish BGP sessions with new credentials

3. **DDoS Attack:**
   - Leverage BGP communities for filtering (20473:666 blackhole)
   - Contact Vultr support for assistance
   - Consider enabling additional upstream filtering