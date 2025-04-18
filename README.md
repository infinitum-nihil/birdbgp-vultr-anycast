# Vultr BGP Anycast Deployment

## Overview
This project automates the deployment of a secure BGP Anycast infrastructure on Vultr, providing high availability across multiple geographic locations with automatic failover.

Key features:
- Automated infrastructure deployment across multiple US regions
- RPKI validation with ARIN TAL prioritization
- ASPA path validation for enhanced security
- Comprehensive security hardening (iptables, CrowdSec, Fail2ban)
- Routinator built from source with ASPA support
- Path prepending for controlled failover
- IPv4 and IPv6 BGP announcement
- Remote Triggered Black Hole (RTBH) for DDoS mitigation

## Prerequisites
Before deploying, you need:
1. A Vultr account with BGP enabled for your ASN
2. Your IP ranges approved for announcement
3. A Vultr API key with full access

## Configuration
Copy the provided `.env.sample` file to `.env` and configure your environment variables:

```bash
cp .env.sample .env
nano .env  # Edit with your actual values
```

Required variables:
```
VULTR_API_KEY=your_api_key_here
VULTR_API_ENDPOINT=https://api.vultr.com/v2/
OUR_AS=your_asn
OUR_IPV4_BGP_RANGE=your_ipv4_range
OUR_IPV6_BGP_RANGE=your_ipv6_range
VULTR_BGP_PASSWORD=your_bgp_password
SSH_KEY_PATH=/absolute/path/to/your/ssh/private_key
```

The script can automatically upload your SSH key to Vultr during deployment if it doesn't already exist in your Vultr account.

## Deployment Architecture
- **Dual-Stack BGP Servers**: 4 servers in different US locations with tiered failover
  - Primary: Newark (ewr) - No path prepending (highest priority)
  - Secondary: Miami (mia) - 1x path prepending (medium priority)
  - Tertiary: Chicago (ord) - 2x path prepending (lowest priority)
  - Los Angeles (lax) - 2x path prepending (lowest priority)
  
All servers are configured with dual-stack BGP and announce both IPv4 and IPv6 prefixes with consistent path prepending hierarchy.

## Usage

### Initial Deployment
```bash
./deploy.sh deploy
```
This will:
1. Check for existing conflicting VMs
2. Deploy all servers in the specified regions
3. Configure Routinator with ASPA support
4. Set up BIRD 2.16.2 with RPKI/ASPA validation
5. Apply comprehensive security hardening
6. Establish BGP sessions and announce your prefixes

### Monitoring
```bash
./deploy.sh monitor
```

For a quick status check of all BGP servers:
```bash
./check_bgp_status_2.sh
```

These commands provide detailed monitoring of:
- Server status
- BGP session state for IPv4 and IPv6
- RPKI validation status
- Routinator operation
- Security service status
- Path prepending verification

### Testing Failover
```bash
./deploy.sh test-failover
```
This stops BIRD on the primary server to verify automatic failover to secondary servers.

### Security Features

#### Remote Triggered Black Hole (RTBH)
For DDoS mitigation, blackhole traffic to a specific IP:
```bash
./deploy.sh rtbh <server_ip> <target_ip>
```

#### ASPA Path Validation
Configure ASPA path validation for enhanced BGP security:
```bash
./deploy.sh aspa <server_ip>
```

#### BGP Communities
Apply BGP communities for traffic engineering:
```bash
./deploy.sh community <server_ip> <community_type> [target_as]
```
Available community types:
- no-advertise
- prepend-1x, prepend-2x, prepend-3x
- no-ixp, ixp-only
- blackhole

### Migration and Cleanup
After successful deployment, clean up old infrastructure:
```bash
./deploy.sh cleanup-old-vm
```

If you need to clean up all resources created by the deployment script:
```bash
./deploy.sh cleanup
```
This will remove all instances, reserved IPs, and SSH keys created by the script.

### SSH Testing
Test SSH connectivity to a server:
```bash
./deploy.sh test-ssh <hostname_or_ip> [username]
```

## Security Implementation
This deployment includes comprehensive security:

1. **Network Security**
   - Strict iptables firewall rules
   - CrowdSec intrusion prevention
   - Fail2ban for brute force protection

2. **BGP Security**
   - RPKI validation with ARIN, RIPE, and Cloudflare validators
   - ASPA path validation
   - BGP password authentication
   - Route coloring via BGP communities

3. **System Hardening**
   - Automatic security updates
   - Kernel parameter hardening via sysctl
   - SSH security configuration
   - Service-specific security settings

4. **DDoS Mitigation**
   - RTBH capability using BGP community 20473:666
   - Integration with Vultr's edge filtering

## Documentation
Detailed documentation is available in the "support docs" directory:
- `deploysteps.md` - Step-by-step deployment process
- `rpki-aspa.md` - RPKI and ASPA configuration details
- `security.md` - Security architecture
- `bgp-communities.md` - Available BGP communities
- `rpki-setup.md` - RPKI validation setup

## Additional Scripts

### Dual-Stack BGP Management
- `check_bgp_status_2.sh` - Check status of all IPv4 and IPv6 BGP sessions
- `bgp_summary.sh` - Display a comprehensive BGP status summary
- `add_ipv6_to_servers.sh` - Add IPv6 connectivity to IPv4-only servers
- `add_ipv6_path_prepending.sh` - Add path prepending to IPv6 BGP sessions

### BIRD Management
- `upgrade_bird.sh` - Upgrade BIRD to version 2.16.2 on a server
- `upgrade_all_servers.sh` - Upgrade all servers to BIRD 2.16.2 with dual-stack
- `fix_ipv6_bgp.sh` - Fix IPv6 BGP configuration issues
- `test_dualstack_bird.sh` - Test dual-stack BGP functionality

### Deployment Tools
- `update_deploy_for_dualstack.sh` - Update deploy.sh with dual-stack support

## License
Copyright (c) 2025. All rights reserved.