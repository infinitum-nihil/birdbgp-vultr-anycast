# BGP Anycast on Vultr: Deployment Guide

This document outlines the complete deployment process for a BGP Anycast setup on Vultr, explaining each step and the reasoning behind it.

## Deployment Overview

Our BGP Anycast deployment consists of:

1. 3 servers for IPv4 BGP with tiered failover
2. 1 server for IPv6 BGP
3. BIRD 2.0 BGP daemon with RPKI validation
4. Vultr BGP communities for routing optimization

## Prerequisites

Before starting deployment, ensure you have:

1. A Vultr account with BGP enabled for your ASN
2. Your IP ranges ready to announce
3. `.env` file with all required variables:
   - `VULTR_API_KEY`: For automating server deployment
   - `VULTR_API_ENDPOINT`: API endpoint for Vultr
   - `OUR_AS`: Your autonomous system number
   - `OUR_IPV4_BGP_RANGE`: IPv4 prefix to announce
   - `OUR_IPV6_BGP_RANGE`: IPv6 prefix to announce
   - `VULTR_BGP_PASSWORD`: BGP password for authentication

## Deployment Steps

### 1. Pre-Deployment Check

Before running the deployment, the script checks if any existing "birdbgp-losangeles" VM is still active.

**What happens:**
- The script checks for existing VMs with the label "birdbgp-losangeles"
- If an active VM is found, the script halts and warns the user
- If a stopped VM is found, the script warns the user but allows continuing
- If no VM is found, deployment proceeds normally

**Why:**
- Prevents conflicting BGP announcements for the same IP ranges
- Avoids routing issues during deployment
- Ensures a clean implementation without legacy configurations
- Provides safety against accidental deployments

### 2. Server Provisioning

```bash
./deploy.sh deploy
```

**What happens:**
- Pre-deployment check for existing birdbgp-losangeles VM
- 4 servers are created in different geographical locations within the Americas
- IPv4 servers: Newark (ewr), Miami (mia), Chicago (ord)
- IPv6 server: Los Angeles (lax)
- All use minimal sizing (1 CPU, 1GB RAM) to reduce costs
- IDs of any existing birdbgp-losangeles VM are saved for later cleanup
- Comprehensive security hardening is automatically applied to all servers:
  - CrowdSec for intrusion detection and prevention
  - Fail2ban for brute force protection
  - Iptables firewall rules with strict defaults
  - Sysctl security hardening
  - Automatic security updates
  - SSH hardening

**Why:**
- Geographic diversity provides route redundancy
- Same region ensures floating IPs are properly supported
- Separating IPv4 and IPv6 follows best practices for BGP setup
- Minimal VM sizing is sufficient for BGP routing with BIRD 2.0
- Security hardening protects these critical BGP infrastructure servers
- Saving old VM IDs allows for cleanup after successful deployment

### 2. Floating IP Assignment

**What happens:**
- Floating IPs are automatically created and assigned to each server
- These IPs remain consistent even if servers change

**Why:**
- Provides stable IP endpoints for services
- Allows for server replacement without IP changes
- Enhances high availability configuration

### 3. BIRD Configuration

**What happens:**
- BIRD 2.0 is installed on all servers
- BGP config is tailored per server with:
  - RPKI validation for security
  - Proper BGP communities 
  - Path prepending on secondary/tertiary servers
  - IPv6-specific routing on the IPv6 server

**Why:**
- BIRD 2.0 is lightweight but powerful for BGP routing
- RPKI validation prevents route hijacking
- Vultr-specific BGP communities optimize routing
- Path prepending ensures traffic prioritization

#### Primary IPv4 Server (Newark)

- No path prepending
- Location community: 20473:11 (Piscataway)
- Origin community: 20473:4000 (customer-originated)

**Why:** This server handles traffic by default with no prepending, making it the primary ingress point.

#### Secondary IPv4 Server (Miami)

- 1x path prepending via community 20473:6001
- Location community: 20473:12 (Miami)

**Why:** Takes over traffic if primary fails; prepending makes it less preferred under normal conditions.

#### Tertiary IPv4 Server (Chicago)

- 2x path prepending via community 20473:6002
- Location community: 20473:13 (Chicago)

**Why:** Last resort backup; double prepending makes it least preferred under normal conditions.

#### IPv6 Server (Los Angeles)

- Standard IPv6 BGP configuration
- Location community: 20473:17 (Los Angeles)
- Large community format: 20473:0:301984017 (Americas-US-LosAngeles)

**Why:** Dedicated IPv6 server provides cleaner separation of IPv4/IPv6 routing.

### 4. Dummy Interface Setup

**What happens:**
- Creates a dummy network interface on each server
- Routes our prefixes via this interface
- Creates additional static routes for Vultr BGP connectivity

**Why:**
- Dummy interfaces are standard practice for announcing BGP prefixes
- Ensures proper routing when packets arrive at the anycast IP
- Essential for multi-server BGP setups

### 5. Vultr-Specific BGP Setup

**What happens:**
- Sets up multihop BGP peering with Vultr (169.254.169.254 and 2001:19f0:ffff::1)
- Adds static route to Vultr's BGP endpoint via link-local address
- Configures BGP authentication with password

**Why:**
- Vultr uses a unique BGP setup with link-local routing
- Static route to 2001:19f0:ffff::1/128 is required but not documented in official Vultr docs
- Proper authentication ensures BGP session security

### 6. Enhanced RPKI Validation with Routinator

**What happens:**
- Installs and configures Routinator (NLnet Labs RPKI Validator)
- Creates custom Routinator configuration with optimized settings
- Sets up SLURM support for local overrides of RPKI data
- Configures multiple RPKI validators for high availability:
  - Local Routinator as primary validator (prioritizing ARIN TAL)
  - ARIN's public validator as first external backup
  - RIPE NCC Validator 3 as second external backup
  - Cloudflare's RPKI validator as final backup
- Implements route coloring with BGP communities based on RPKI status:
  - ${OUR_AS}:1001 = RPKI Valid
  - ${OUR_AS}:1002 = RPKI Unknown
  - ${OUR_AS}:1000 = RPKI Invalid (before rejection)
- Validates all received BGP routes against RPKI database
- Rejects RPKI invalid routes automatically
- Provides comprehensive monitoring of RPKI validation status

**Why:**
- Routinator is a modern, efficient RPKI validator
- Local validator reduces dependency on external services
- Triple validators provide high availability
- SLURM support allows for local exceptions when needed
- Route coloring allows for traffic engineering based on RPKI status
- Prevents route hijacking and improves security
- Enhanced metrics and monitoring for operational awareness
- Follows industry best practices for BGP security
- Optimized configuration for better performance and reliability
- Enables future policy flexibility based on route origin validation

### 7. BGP Community Configuration

**What happens:**
- Sets appropriate BGP communities for each server
- Configures origin community (20473:4000)
- Adds location-specific communities
- Uses path prepending communities for failover

**Why:**
- Vultr BGP communities optimize routing behavior
- Location communities help with geographic routing
- Path prepending via communities is more efficient than manual prepending
- Provides more control over traffic engineering

## Post-Deployment Tasks

### 1. Monitoring

```bash
./deploy.sh monitor
```

**What happens:**
- Checks all server statuses via Vultr API
- Verifies BGP session establishment
- Checks RPKI validation status
- Confirms route announcements

**Why:**
- Ensures BGP sessions are properly established
- Verifies routes are correctly announced
- Confirms RPKI validation is working

### 2. Failover Testing

```bash
./deploy.sh test-failover
```

**What happens:**
- Stops BIRD on the primary server
- Tests traffic rerouting to secondary server

**Why:**
- Validates that failover mechanism works
- Ensures high availability functions properly
- Verifies path prepending is working correctly

### 3. BGP Community Manipulation

```bash
./deploy.sh community <server_ip> <community_type> [target_as]
```

**What happens:**
- Dynamically updates BGP communities on a specific server
- Can target specific ASNs or apply globally
- Supports multiple routing policies (no-advertise, prepending, etc.)

**Why:**
- Provides runtime traffic engineering capabilities
- Allows targeted routing adjustments without reconfiguration
- Enables response to network conditions or business requirements

## Troubleshooting Common Issues

### BGP Session Not Establishing

**Check:**
1. Verify BGP password is correct
2. Ensure static route to 2001:19f0:ffff::1 is properly configured
3. Check firewall allows TCP port 179

**Why:** These are the most common causes of BGP session failures with Vultr.

### Routes Not Being Announced

**Check:**
1. Verify dummy interface is properly configured
2. Check BIRD configuration for export filters
3. Ensure BGP session is established

**Why:** Route announcement requires proper interface setup and export filters.

### RPKI Validation Issues

**Check:**
1. Ensure BIRD has internet access
2. Check if RPKI validator is reachable
3. Verify RPKI table is populated

**Why:** RPKI validation depends on external connectivity to validators.

### Post-Deployment Cleanup

After verifying that the new BGP Anycast infrastructure is functioning correctly, you can clean up the old VM:

```bash
./deploy.sh cleanup-old-vm
```

**What happens:**
- Checks for saved ID of the old birdbgp-losangeles VM
- Verifies the VM's status and stops it if still running
- Requests explicit confirmation (typing "DELETE") before proceeding
- Permanently deletes the old VM
- Removes the saved VM ID file

**Why:**
- Prevents unnecessary resource usage and billing
- Ensures clean environment without legacy VMs
- Built-in safeguards prevent accidental deletion
- Confirmation requirement adds safety

## Best Practices

1. **Regular Monitoring:** Monitor BGP sessions and route announcements
2. **Periodic Testing:** Test failover regularly to ensure it works as expected
3. **Community Management:** Use BGP communities for fine-grained routing control
4. **Update Management:** Keep BIRD and OS updated for security and stability
5. **Backup Configuration:** Maintain backups of your BGP configuration
6. **Resource Management:** Clean up unused resources after successful deployment

## Advanced Configuration

For specialized routing needs, consider using targeted BGP communities:

1. **Traffic Shaping:** Use communities to balance traffic between regions
2. **AS Targeting:** Apply specific routing policies to particular autonomous systems
3. **Blackholing:** Use 20473:666 to request upstream DDoS mitigation
4. **IXP Control:** Use 20473:6601/6602 to control announcement to Internet Exchange Points

## Migration Checklist

When migrating from an existing setup to this new infrastructure:

1. **Pre-Deployment**: Verify existing VM and ensure it's identified correctly
2. **Deployment**: Run deployment and verify new setup works correctly
3. **Testing**: Confirm all BGP sessions are established properly
4. **Transition**: Route traffic gradually to the new infrastructure
5. **Validation**: Verify services work correctly on new infrastructure
6. **Cleanup**: Remove old infrastructure using the cleanup-old-vm command

By following these deployment steps and best practices, you'll have a robust, secure, and optimized BGP Anycast setup on Vultr that provides high availability and efficient routing for your services.