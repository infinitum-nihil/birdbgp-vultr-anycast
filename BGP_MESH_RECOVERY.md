# BGP Mesh Network Recovery Plan

This document outlines the steps to recover the BGP mesh network after server connectivity issues.

## Current Status

As of the last check:
- LAX (149.248.2.74) - Unreachable (primary/route reflector)
- ORD (66.42.113.101) - Unreachable (secondary)
- MIA (149.28.108.180) - Reachable (tertiary)
- EWR (66.135.18.138) - Unreachable (quaternary)

## Recovery Steps

### Scenario 1: All Servers Become Reachable

1. **Verify Server Connectivity**
   ```bash
   # Run this for each server
   ssh -o ConnectTimeout=10 root@<SERVER_IP> "hostname"
   ```

2. **Update Router IDs on All Servers**
   ```bash
   # Run for each server that hasn't been updated yet
   /home/normtodd/birdbgp/fix_bird_router_ids.sh <server_name>
   ```

3. **Verify WireGuard Connectivity**
   ```bash
   /home/normtodd/birdbgp/check_mesh_connectivity.sh
   ```

4. **Restore Original LAX-as-RR Configuration**
   ```bash
   /home/normtodd/birdbgp/fix_bird_config.sh
   ```

5. **Verify BGP Sessions**
   ```bash
   # For each server
   ssh root@<SERVER_IP> "birdc show protocols | grep BGP"
   ```

### Scenario 2: LAX Remains Unreachable, Other Servers Recovered

1. **Verify Server Connectivity** (as above)

2. **Update Router IDs on Available Servers**
   ```bash
   # Run for each available server
   /home/normtodd/birdbgp/fix_bird_router_ids.sh <server_name>
   ```

3. **Configure ORD as Temporary Route Reflector**
   ```bash
   /home/normtodd/birdbgp/configure_temp_rr.sh
   ```

4. **Verify BGP Sessions** (as above)

### Scenario 3: Only Some Servers Recovered

1. **Start with Available Servers**
   - Update router IDs on all available servers
   - If at least two servers are available, establish BGP between them
   
2. **Gradually Add Servers as They Become Available**
   - When a server becomes available, update its router ID and BIRD configuration
   - Add it to the mesh network
   
3. **Monitor Progress**
   - Regularly check BGP session status
   - Monitor WireGuard connectivity
   - Keep track of which servers have been recovered

## Configuration Templates

### LAX as Route Reflector (Default)

iBGP Configuration for LAX:
```
# iBGP Configuration for mesh network
# LAX is the route reflector (10.10.10.1)

define SELF_ASN = 27218;

template bgp ibgp_clients {
  local as SELF_ASN;
  rr client;
  rr cluster id 1;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}

# Client configurations
protocol bgp ibgp_ord {
  local as SELF_ASN;
  neighbor 10.10.10.2 as SELF_ASN;
  description "iBGP to ORD";
  rr client;
  rr cluster id 1;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}

protocol bgp ibgp_mia {
  local as SELF_ASN;
  neighbor 10.10.10.3 as SELF_ASN;
  description "iBGP to MIA";
  rr client;
  rr cluster id 1;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}

protocol bgp ibgp_ewr {
  local as SELF_ASN;
  neighbor 10.10.10.4 as SELF_ASN;
  description "iBGP to EWR";
  rr client;
  rr cluster id 1;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}
```

iBGP Configuration for Client Servers:
```
# iBGP Configuration for mesh network
# Client configuration pointing to LAX as route reflector (10.10.10.1)

define SELF_ASN = 27218;

protocol bgp ibgp_rr {
  local as SELF_ASN;
  neighbor 10.10.10.1 as SELF_ASN;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
  description "iBGP to Route Reflector (LAX)";
}
```

### ORD as Route Reflector (Backup)

iBGP Configuration for ORD:
```
# iBGP Configuration for mesh network
# ORD is the temporary route reflector (10.10.10.2)

define SELF_ASN = 27218;

template bgp ibgp_clients {
  local as SELF_ASN;
  rr client;
  rr cluster id 2;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}

# LAX iBGP peer (if available)
protocol bgp ibgp_lax {
  local as SELF_ASN;
  neighbor 10.10.10.1 as SELF_ASN;
  description "iBGP to LAX";
  rr client;
  rr cluster id 2;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}

# MIA iBGP peer
protocol bgp ibgp_mia {
  local as SELF_ASN;
  neighbor 10.10.10.3 as SELF_ASN;
  description "iBGP to MIA";
  rr client;
  rr cluster id 2;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}

# EWR iBGP peer
protocol bgp ibgp_ewr {
  local as SELF_ASN;
  neighbor 10.10.10.4 as SELF_ASN;
  description "iBGP to EWR";
  rr client;
  rr cluster id 2;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
}
```

iBGP Configuration for Client Servers:
```
# iBGP Configuration for mesh network
# Client configuration pointing to ORD as temporary route reflector (10.10.10.2)

define SELF_ASN = 27218;

protocol bgp ibgp_rr {
  local as SELF_ASN;
  neighbor 10.10.10.2 as SELF_ASN;
  direct;
  ipv4 {
    import all;
    export all;
    next hop self;
  };
  description "iBGP to Route Reflector (ORD)";
}
```

## Troubleshooting Commands

```bash
# Check WireGuard interface
wg show

# Check WireGuard connectivity
ping -c 3 10.10.10.1  # LAX
ping -c 3 10.10.10.2  # ORD
ping -c 3 10.10.10.3  # MIA
ping -c 3 10.10.10.4  # EWR

# Check BIRD status
systemctl status bird

# Check BIRD routes
birdc show route

# Check BGP sessions
birdc show protocols

# Check firewall rules
iptables -L -n

# Restart BIRD
systemctl restart bird

# Check router ID
birdc show status | grep 'Router ID'
```

## Important Notes

1. **Router IDs**: Ensure that router IDs are set to public IPs, not private WireGuard IPs
2. **Firewall Rules**: Make sure firewalls allow BGP traffic (TCP port 179) and WireGuard traffic
3. **Server Priority**: LAX is the primary/route reflector, followed by ORD, MIA, and EWR
4. **BGP Sessions**: iBGP requires all servers to have the same AS number (27218)
5. **Testing**: Always test BGP sessions after configuration changes