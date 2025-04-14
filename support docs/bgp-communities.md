# Vultr BGP Communities Guide

This document provides information about BGP communities supported by Vultr (AS20473) and how they're implemented in our deployment.

## Informational Communities

Vultr tags prefixes with informational communities to indicate their origin:

| Prefix Type | Community | Large Community |
|-------------|-----------|-----------------|
| Prefix learned from Transit | 20473:100 | 20473:100:transit-as |
| Prefix learned from Public Peer via route servers | 20473:200 | 20473:200:ixp-as |
| Prefix learned from Public Peer via bilateral peering | 20473:200 | 20473:200:ixp-as, 20473:200:peer-as |
| Prefix learned from Private Peer | 20473:300 | 20473:300:peer-as |
| Prefix originated by Customer | 20473:4000 | |
| Prefix originated by 20473 | 20473:500 | |

Our script automatically adds the `20473:4000` community to all prefixes we announce.

## Location Communities

Vultr tags prefixes with location-based communities. The following are used in our deployment:

| Location | POP Code |
|----------|----------|
| Piscataway, NJ (nearest to Newark) | 11 |
| Miami, FL | 12 |
| Chicago, IL | 13 |
| Los Angeles, CA | 17 |

Our script automatically adds the appropriate location community based on each server's region.

Large communities are also used for location with the format `20473:0:3RRRCCC1PP` where:
- RRR is the M49 region code
- CCC is the M49 country code
- PP is the location code

## Action Communities

These communities allow us to influence traffic for prefixes advertised outside of AS20473:

| Action | Community | Large Community |
|--------|-----------|-----------------|
| Do not advertise to specific AS | 64600:peer-as | 20473:6000:peer-as |
| Prepend 1x to specific AS | 64601:peer-as | 20473:6001:peer-as |
| Prepend 2x to specific AS | 64602:peer-as | 20473:6002:peer-as |
| Prepend 3x to specific AS | 64603:peer-as | 20473:6003:peer-as |
| Set Metric to 0 to specific AS | 64609:peer-as | 20473:6009:peer-as |
| Override 20473:6000 to specific AS | 64699:peer-as | 20473:6099:peer-as |
| Do not advertise out of AS20473 | 20473:6000 | |
| Prepend 1x to all peers | 20473:6001 | |
| Prepend 2x to all peers | 20473:6002 | |
| Prepend 3x to all peers | 20473:6003 | |
| Set Metric to 0 to all peers | 20473:64609 | |
| Do not announce to IXP peers | 20473:6601 | |
| Announce to IXP route servers only | 20473:6602 | |
| Export blackhole to all peers | 20473:666 | |

Our script uses these communities to control path prepending:
- Primary server: No prepending
- Secondary server: Uses 20473:6001 (prepend 1x to all peers)
- Tertiary server: Uses 20473:6002 (prepend 2x to all peers)

## Using Communities for Traffic Engineering

### Path Prepending

Instead of manually prepending AS paths in BIRD configurations, we use Vultr's communities:

```
bgp_community.add((20473,6001)); # Prepend 1x to all peers
bgp_community.add((20473,6002)); # Prepend 2x to all peers
bgp_community.add((20473,6003)); # Prepend 3x to all peers
```

### Targeted Traffic Control

To control routing to specific autonomous systems:

```
# Don't advertise to AS12345
bgp_community.add((64600,12345));
bgp_large_community.add((20473,6000,12345));

# Prepend 2x to AS67890
bgp_community.add((64602,67890));
bgp_large_community.add((20473,6002,67890));
```

### Controlling IXP Announcements

You can control whether routes are announced to Internet Exchange Points:

```
# Do not announce to IXP peers
bgp_community.add((20473,6601));

# Announce to IXP route servers only
bgp_community.add((20473,6602));
```

## Runtime Community Management

Our deployment script provides a command to add communities to running instances:

```bash
# Apply a community to all peers
./deploy.sh community <server_ip> <community_type>

# Apply a community targeting a specific AS
./deploy.sh community <server_ip> <community_type> <target_as>
```

Available community types:
- no-advertise: Prevent route advertisement
- prepend-1x: Prepend once
- prepend-2x: Prepend twice
- prepend-3x: Prepend three times
- no-ixp: Don't announce to IXP peers
- ixp-only: Announce only to IXP route servers
- blackhole: Export blackhole to all peers

Example:

```bash
# Prepend 2x to all peers from the primary server
./deploy.sh community 192.168.1.1 prepend-2x

# Don't advertise to AS12345 from the secondary server
./deploy.sh community 192.168.1.2 no-advertise 12345
```