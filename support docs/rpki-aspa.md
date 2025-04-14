# RPKI and ASPA Configuration in the BGP Anycast Setup

This document explains how Resource Public Key Infrastructure (RPKI) and Autonomous System Provider Authorization (ASPA) are implemented in our BGP Anycast setup.

## Building Routinator with ASPA Support

The standard packaged version of Routinator does not include ASPA support. To use ASPA validation, we need to build Routinator from source with the ASPA feature flag enabled.

### Build Process

Our deployment script handles this automatically with the following steps:

1. Install build dependencies:
   ```bash
   apt-get install -y build-essential curl gnupg
   ```

2. Install Rust toolchain:
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
   . "$HOME/.cargo/env"
   ```

3. Build Routinator with ASPA feature flag:
   ```bash
   cargo install --locked --features aspa routinator
   ```

4. Make Routinator accessible:
   ```bash
   ln -sf "$HOME/.cargo/bin/routinator" /usr/local/bin/routinator
   ```

### Routinator Configuration

Routinator is configured in `/etc/routinator/routinator.conf` with ASPA support:

```
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

# SLURM support for local exceptions
slurm = "/etc/routinator/slurm.json"
```

### Systemd Service Configuration

Routinator runs as a systemd service with ASPA enabled:

```
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
```

## ASPA Configuration in BIRD 2.0

ASPA validation is configured in BIRD 2.0 through the `aspa.conf` file.

### ASPA Protocol Configuration

The ASPA data is sourced from Routinator:

```
# Import ASPA data from Routinator
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
```

### Path Validation Function

We define an ASPA validation function to verify the expected AS path relationships:

```
# Authorized providers for our ASN
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
```

This function ensures that our BGP routes only use Vultr (AS64515) as an upstream provider, preventing route leaks and certain types of BGP hijacking.

### Integrated Route Security

ASPA validation is combined with RPKI validation for comprehensive route security:

```
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
```

This function:
1. Rejects RPKI invalid routes
2. Enforces ASPA path validation
3. Adds BGP communities to indicate RPKI validation status

## Using ASPA in Practice

### Enabling ASPA on Existing Servers

To enable ASPA on an existing server:

```bash
./deploy.sh aspa <server_ip>
```

This command will:
1. Create the ASPA configuration on the server
2. Update the BGP import filters to use enhanced route security
3. Restart BIRD to activate the changes

### Monitoring ASPA Status

You can monitor the ASPA status with:

```bash
# Check ASPA protocol status
birdc show protocols aspa_source

# Examine ASPA table
birdc show route table aspa_table count

# Check ASPA logs
birdc show log | grep ASPA
```

## Implementation Details

### Technical Considerations

1. **ASPA Standardization**: ASPA is a newer BGP security extension that is still evolving. Our implementation follows current best practices.

2. **Data Prefetching**: The ASPA configuration includes extended timeouts to ensure data is available before BGP sessions start.

3. **Memory Requirements**: ASPA validation requires additional memory. We've increased Routinator's memory limits to accommodate this.

4. **Path Validation Specifics**: We're specifically validating that Vultr (AS64515) is our only upstream provider, which aligns with our BGP Anycast deployment on Vultr's platform.

### Security Benefits

1. **Route Leak Prevention**: ASPA validation prevents routes from being propagated through unexpected providers.

2. **Hijacking Mitigation**: Combined with RPKI, ASPA helps detect and prevent certain forms of BGP hijacking.

3. **Path Integrity**: Ensures BGP paths follow expected and authorized provider relationships.

4. **Community Tagging**: Routes are tagged with BGP communities indicating their validation status, which can be used for traffic engineering.

## ASPA Resources

For more information on ASPA:

1. [IETF Draft: ASPA Validation](https://datatracker.ietf.org/doc/draft-ietf-sidrops-aspa-verification/)
2. [NLnet Labs Routinator Documentation](https://routinator.docs.nlnetlabs.nl/)
3. [RIPE NCC - ASPA Document Store](https://rpki.ripe.net/aspa/)
4. [BIRD Documentation on ASPA](https://bird.network.cz/)