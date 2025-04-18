# Vultr BGP Anycast Deployment

## Overview
This project automates the deployment of a secure BGP Anycast infrastructure on Vultr, providing high availability across multiple geographic locations with automatic failover.

Key features:
- Automated infrastructure deployment across any global regions
- Configurable region-agnostic BGP hierarchy with role reassignment
- RPKI validation with ARIN TAL prioritization
- ASPA path validation for enhanced security
- Comprehensive security hardening (iptables, CrowdSec, Fail2ban)
- Routinator built from source with ASPA support
- Path prepending for controlled failover
- Dual-stack IPv4 and IPv6 BGP announcement
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
# API and BGP credentials
VULTR_API_KEY=your_api_key_here
VULTR_API_ENDPOINT=https://api.vultr.com/v2/
OUR_AS=your_asn
OUR_IPV4_BGP_RANGE=your_ipv4_range
OUR_IPV6_BGP_RANGE=your_ipv6_range
VULTR_BGP_PASSWORD=your_bgp_password
SSH_KEY_PATH=/absolute/path/to/your/ssh/private_key

# Region configuration - each role can be assigned to any valid Vultr region
BGP_REGION_PRIMARY=ewr     # Primary region (no path prepending)
BGP_REGION_SECONDARY=mia   # Secondary region (1x path prepending)
BGP_REGION_TERTIARY=ord    # Tertiary region (2x path prepending)
BGP_REGION_QUATERNARY=lax  # Quaternary region (2x path prepending)
```

The script can automatically upload your SSH key to Vultr during deployment if it doesn't already exist in your Vultr account.

## Deployment Architecture
- **Dual-Stack BGP Servers**: 4 servers with tiered failover (regions configurable)
  - Primary: No path prepending (highest priority)
  - Secondary: 1x path prepending (medium priority) 
  - Tertiary: 2x path prepending (lowest priority)
  - Quaternary: 2x path prepending (lowest priority)

All servers are configured with dual-stack BGP and announce both IPv4 and IPv6 prefixes with a consistent path prepending hierarchy. You can deploy these servers in any Vultr regions worldwide by configuring the region codes in your `.env` file, allowing for global anycast distribution tailored to your needs.

### BIRD 2.16.2 Implementation
This deployment uses BIRD 2.16.2, which is built from source on each machine. Key reasons for using this specific version:

1. **Enhanced IPv6 Support**: Version 2.16.2 contains critical fixes for IPv6 BGP sessions and multihop BGP
2. **RPKI Improvements**: Better handling of RPKI validation, including more reliable ROA checks
3. **Improved Stability**: Fixes for session flapping issues that were present in earlier versions
4. **Path Prepending Efficiency**: More reliable AS path prepending for traffic engineering
5. **Multi-Protocol BGP**: Better support for running IPv4 and IPv6 BGP sessions simultaneously

The `upgrade_bird.sh` script provides automated installation of BIRD 2.16.2 from source with all required dependencies.

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
./check_bgp_status.sh
```

These commands provide detailed monitoring of:
- Server status with role and region information
- BGP session state for IPv4 and IPv6
- RPKI validation status
- Path prepending configuration verification
- Routinator operation
- Security service status

### Reassigning Server Roles
To change which server acts as primary, secondary, tertiary, or quaternary:
```bash
./reassign_bgp_roles.sh --primary <region> --secondary <region> --tertiary <region> --quaternary <region>
```

For example, to make LAX the primary server:
```bash
./reassign_bgp_roles.sh --primary lax --secondary ewr --tertiary mia --quaternary ord
```

This will:
1. Update your .env file with the new role assignments
2. Reconfigure BIRD on all affected servers
3. Update path prepending to match new roles
4. Maintain dual-stack IPv4+IPv6 BGP announcements

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
   - ASPA path validation using Routinator and BIRD 2.16.2
   - BGP password authentication with Vultr peer
   - Route coloring via BGP communities
   - Path prepending for traffic engineering and controlled failover
   - BIRD 2.16.2 security features including prefix filtering and session protection

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

### BGP Role Management
- `reassign_bgp_roles.sh` - Change which server is primary/secondary/tertiary/quaternary
- `check_bgp_status.sh` - Region-agnostic status check with role and prepending info
- `check_bgp_status_updated.sh` - Alternative status check with enhanced output

### Dual-Stack BGP Management
- `bgp_summary.sh` - Display a comprehensive BGP status summary
- `add_ipv6_to_servers.sh` - Add IPv6 connectivity to IPv4-only servers
- `add_ipv6_path_prepending.sh` - Add path prepending to IPv6 BGP sessions

### BIRD Management
- `upgrade_bird.sh` - Upgrade BIRD to version 2.16.2 from source, including dependencies
- `upgrade_all_servers.sh` - Upgrade all servers to BIRD 2.16.2 with dual-stack support
- `fix_ipv6_bgp.sh` - Fix IPv6 BGP configuration issues and establish IPv6 sessions
- `test_dualstack_bird.sh` - Test dual-stack BGP functionality (IPv4+IPv6)

The BIRD 2.16.2 upgrade is essential for proper dual-stack operation. Earlier versions (like 2.0.8) have several IPv6 related issues, particularly with multihop BGP sessions and route advertisement. The upgrade process preserves your existing configuration while enhancing capabilities.

### Deployment Tools
- `update_deploy_for_dualstack.sh` - Update deploy.sh with dual-stack support

## License
Copyright (c) 2025. All rights reserved.