# BGP Diagnostic Tools

This directory contains diagnostic and testing scripts used to verify specific aspects of the BGP setup. These scripts are not part of the main deployment process but are kept as tools for troubleshooting and verification.

## Available Tools

### BGP Configuration & Verification
- **fix_bird_final.sh**: Main BIRD configuration verification and repair
- **fix_bird.sh**, **fix_bird_again.sh**: Alternative BIRD configuration fixes
- **fix_bird_restart.sh**: Handles BIRD service restart issues
- **verify_bgp_config.sh**: Comprehensive BGP configuration verification
- **check_bgp_status.sh**, **check_bgp_status_2.sh**, **check_bgp_status_updated.sh**: BGP status monitoring
- **bgp_summary.sh**: Quick BGP session summary

### IPv6-specific Tools
- **fix_ipv6_bgp.sh**: Basic IPv6 BGP troubleshooting
- **fix_ipv6_bgp_advanced.sh**: Advanced IPv6 BGP configuration
- **fix_ipv6_bgp_final.sh**: Final IPv6 BGP setup verification
- **fix_ipv6_bgp_firewall.sh**: IPv6 firewall rules for BGP
- **fix_ipv6_bgp_simplest.sh**: Minimal IPv6 BGP configuration test

### Network Configuration
- **fix_anycast_forwarding.sh**: Anycast IP forwarding verification
- **fix_anycast_routing.sh**: Anycast routing configuration
- **fix_device_routes.sh**: Network device routes configuration
- **fix_blackhole_routes.sh**: Blackhole routes verification
- **fix_socket_permissions.sh**: BIRD socket permissions repair

### Vultr-specific Tools
- **fix_vultr_bgp.sh**: Vultr BGP session configuration
- **fix_bgp_password.sh**: BGP password configuration for Vultr
- **fix_bgp_full.sh**: Complete BGP setup for Vultr

## Usage Examples

### Verifying BGP Status
```bash
./check_bgp_status.sh
```

### Testing IPv6 Configuration
```bash
./fix_ipv6_bgp.sh
```

### Checking Anycast Setup
```bash
./fix_anycast_forwarding.sh
```

## When to Use These Tools

1. **Initial Setup**: Verifying components during initial deployment
2. **Troubleshooting**: When specific components aren't working as expected
3. **Maintenance**: Regular health checks of the BGP setup
4. **Updates**: After making changes to verify functionality

## Note
These scripts were created during the initial setup and testing phase. They are maintained separately from the main deployment script to keep the codebase clean while preserving their utility for diagnostic purposes.

## Best Practices
1. Always check the script contents before running
2. Use with caution in production environments
3. Keep track of any changes made using these tools
4. Consider running in test mode first when available 