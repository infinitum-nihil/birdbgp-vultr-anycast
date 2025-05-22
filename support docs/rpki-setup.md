# DISCLAIMER AND DATE INFORMATION

**Last Updated:** May 22, 2025

## Educational Use Only Disclaimer

This document is provided for educational purposes only. The information contained herein:

1. **No Warranty**: Is provided "as is" without any warranties of any kind, either express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, or non-infringement.

2. **No Guarantee of Security**: Does not guarantee complete security when implemented. Users must conduct their own security assessments and implement additional security measures appropriate to their specific environments and requirements.

3. **User Responsibility**: Places the responsibility on the user to follow their own organization's security policies, industry best practices, and applicable laws and regulations.

4. **No Liability**: The authors and contributors of this document shall not be liable for any direct, indirect, incidental, special, exemplary, or consequential damages resulting from the use or misuse of any information contained herein.

5. **Technical Changes**: Security standards and best practices evolve over time. Users should regularly check for updated versions of this document and review current industry standards.

By using this document, you acknowledge that you have read and understood this disclaimer and agree to use the information at your own risk.

---

# Enhanced RPKI Validation in BIRD 2.0 with Routinator

## Overview
This guide explains how to configure comprehensive Resource Public Key Infrastructure (RPKI) validation in BIRD 2.0 using Routinator and multiple fallback validators for your Vultr BGP setup. This enhances security by validating the origin of BGP routes and implementing route tagging with communities.

## Prerequisites
- BIRD 2.0 installed and configured for BGP
- Internet connectivity to access RPKI validator servers
- Root access to server

## Installation Steps

### 1. Install Routinator and RPKI Tools

```bash
# Install RTRlib and BIRD RPKI client support
apt-get update
apt-get install -y rtrlib-tools bird2-rpki-client

# Add NLnet Labs repository
apt-get install -y curl gnupg
curl -sSL https://packages.nlnetlabs.nl/aptkey.asc | apt-key add -
echo "deb [arch=amd64] https://packages.nlnetlabs.nl/linux/debian bullseye main" > /etc/apt/sources.list.d/nlnetlabs.list

# Install Routinator
apt-get update
apt-get install -y routinator
```

### 2. Configure Routinator with Optimization

Create a custom Routinator configuration for optimal performance:

```bash
# Create configuration directory
mkdir -p /etc/routinator

# Create optimized configuration
cat > /etc/routinator/routinator.conf << 'RPKICONF'
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
# Enable all available features
enable-aspa = true
enable-bgpsec = true

# SLURM (Simplified Local Internet Number Resource Management) support
# Allows for local exceptions to RPKI data
slurm = "/etc/routinator/slurm.json"
RPKICONF
```

### 3. Configure SLURM for Local Exceptions

Create a basic SLURM configuration for local exceptions to RPKI data:

```bash
cat > /etc/routinator/slurm.json << 'SLURM'
{
  "slurmVersion": 1,
  "validationOutputFilters": {
    "prefixFilters": [],
    "bgpsecFilters": []
  },
  "locallyAddedAssertions": {
    "prefixAssertions": [],
    "bgpsecAssertions": []
  }
}
SLURM

# Set proper permissions
chown -R routinator:routinator /etc/routinator
```

### 4. Configure System Resources for Routinator

Create a systemd override to ensure Routinator has adequate resources:

```bash
mkdir -p /etc/systemd/system/routinator.service.d/
cat > /etc/systemd/system/routinator.service.d/override.conf << 'SYSTEMD'
[Service]
# Set higher memory limits for Routinator
MemoryHigh=512M
MemoryMax=1G
SYSTEMD

# Reload systemd
systemctl daemon-reload
```

### 5. Initialize and Start Routinator

```bash
# Copy ARIN TAL directly to Routinator's TAL directory
cp /path/to/arin.tal /var/lib/routinator/tals/
chown routinator:routinator /var/lib/routinator/tals/arin.tal

# Initialize Routinator (no need to accept RPA as we have the TAL)
routinator init

# Enable and start service
systemctl enable --now routinator
```

### 6. Configure RPKI in BIRD 2.0 with Triple Redundancy

Edit your BIRD configuration file (`/etc/bird/bird.conf`) to add triple-redundant RPKI validators:

```
# RPKI Configuration
roa table rpki_table;

# Use local Routinator as primary RPKI validator
# This uses ARIN TAL as a priority
protocol rpki rpki_routinator {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "localhost" port 8323;  # Routinator local RTR server
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Use ARIN's validator as first external fallback
protocol rpki rpki_arin {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.arin.net" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# RIPE NCC Validator 3 as second external fallback
protocol rpki rpki_ripe {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rpki-validator3.ripe.net" port 8323;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}

# Cloudflare's RPKI validator as final fallback
protocol rpki rpki_cloudflare {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.cloudflare.com" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}
```

### 7. Configure Enhanced RPKI Filtering with Route Coloring

Add a comprehensive filter function with BGP community tagging:

```
# Enhanced RPKI validation function with route coloring (communities)
function rpki_check() {
  # Store original validation state for community tagging
  case roa_check(rpki_table, net, bgp_path.last) {
    ROA_VALID: {
      # Add community to mark route as RPKI valid
      bgp_community.add((${OUR_AS}, 1001));
      print "RPKI: Valid route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_UNKNOWN: {
      # Add community to mark route as RPKI unknown
      bgp_community.add((${OUR_AS}, 1002));
      print "RPKI: Unknown route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_INVALID: {
      # Add community to mark route as RPKI invalid before rejecting
      bgp_community.add((${OUR_AS}, 1000));
      print "RPKI: Invalid route: ", net, " ASN: ", bgp_path.last;
      reject;
    }
  }
}
```

### 8. Apply RPKI Validation to BGP Sessions

Modify your BGP protocol section to include RPKI validation:

```
# Example for IPv4 BGP
protocol bgp vultr {
  local as YOUR_ASN;
  source address YOUR_IPV4;
  ipv4 {
    import where rpki_check();  # Apply RPKI validation to incoming routes
    export filter {
      # Only export routes from direct and static protocols
      if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
        accept;
      } else {
        reject;
      }
    };
  };
  graceful restart on;
  multihop 2;
  neighbor 169.254.169.254 as 64515;
  password "YOUR_BGP_PASSWORD";
}

# Example for IPv6 BGP
protocol bgp vultr6 {
  local as YOUR_ASN;
  source address YOUR_IPV6;
  ipv6 {
    import where rpki_check();  # Apply RPKI validation to incoming routes
    export filter {
      # Only export routes from direct and static protocols
      if source ~ [ RTS_DEVICE, RTS_STATIC ] then {
        accept;
      } else {
        reject;
      }
    };
  };
  graceful restart on;
  multihop 2;
  neighbor 2001:19f0:ffff::1 as 64515;
  password "YOUR_BGP_PASSWORD";
}
```

### 9. Monitor RPKI Validation Status

Use the following commands to monitor RPKI validation:

```bash
# Check RPKI validator status
birdc show protocols rpki_routinator
birdc show protocols rpki_ripe
birdc show protocols rpki_cloudflare

# Check Routinator service status
systemctl status routinator

# Check ROA table statistics
birdc show route table rpki_table count

# Verify specific route validation
birdc eval 'roa_check(rpki_table, 192.30.120.0/23, 27218)'

# Check Routinator metrics
curl -s http://localhost:8080/metrics | grep -i rpki

# Check RPKI cached object count
routinator vrps stats
```

## Using ARIN TAL as Priority

ARIN is the Regional Internet Registry (RIR) for the United States and many parts of North America. Using the ARIN Trust Anchor Locator (TAL) as priority in your RPKI validation chain has several benefits:

1. More relevant ROAs for North American networks
2. Potentially faster validation for North American prefixes
3. Direct validation with the authoritative source for AS numbers in North America

### Obtaining and Installing ARIN TAL

The ARIN TAL file contains the URL to ARIN's Certificate Authority certificate and the public key needed to verify it. The file is typically named `arin.tal`.

```bash
# Contents of arin.tal include:
rsync://rpki.arin.net/repository/arin-rpki-ta.cer
https://rrdp.arin.net/arin-rpki-ta.cer

MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3lZPjbHvMRV5sDDqfLc/685th5FnreHMJjg8
pEZUbG8Y8TQxSBsDebbsDpl3Ov3Cj1WtdrJ3CIfQODCPrrJdOBSrMATeUbPC+JlNf2SRP3UB+VJFgtTj
0RN8cEYIuhBW5t6AxQbHhdNQH+A1F/OJdw0q9da2U29Lx85nfFxvnC1EpK9CbLJS4m37+RlpNbT1cba+
b+loXpx0Qcb1C4UpJCGDy7uNf5w6/+l7RpATAHqqsX4qCtwwDYlbHzp2xk9owF3mkCxzl0HwncO+sEHH
eaL3OjtwdIGrRGeHi2Mpt+mvWHhtQqVG+51MHTyg+nIjWFKKGx1Q9+KDx4wJStwveQIDAQAB
```

The ARIN TAL can be obtained in two ways:
1. Download from [ARIN's website](https://www.arin.net/resources/manage/rpki/tal/)
2. Use a pre-installed TAL from our deployment package

When using Routinator, it's important to place this file in the correct location:

```bash
# Create Routinator's TAL directory if it doesn't exist
mkdir -p /var/lib/routinator/tals

# Copy ARIN TAL to the TAL directory
cp /path/to/arin.tal /var/lib/routinator/tals/

# Set appropriate permissions
chown -R routinator:routinator /var/lib/routinator/tals
```

### Connecting to ARIN's Public RTR Service

ARIN provides a public RTR service at `rtr.rpki.arin.net` port `8282` that can be used as an external validator. This service allows BIRD to directly connect to ARIN's RPKI validator without needing to run a local validator like Routinator.

To connect directly to ARIN's RTR service:

```
protocol rpki rpki_arin {
  roa4 { table rpki_table; };
  roa6 { table rpki_table; };
  remote "rtr.rpki.arin.net" port 8282;
  retry keep 600;
  refresh keep 600;
  expire keep 7200;
}
```

For optimal performance and reliability, we recommend using a local Routinator instance with the ARIN TAL as your primary validator, and the ARIN RTR service as your first fallback.

## Advanced RPKI Configurations

### SLURM Configuration Examples

You can modify `/etc/routinator/slurm.json` to create local exceptions to RPKI data:

#### Example 1: Filtering Out Unwanted ROAs

```json
{
  "slurmVersion": 1,
  "validationOutputFilters": {
    "prefixFilters": [
      {
        "prefix": "192.0.2.0/24",
        "asn": 64496,
        "comment": "Filter this ROA from validation"
      }
    ],
    "bgpsecFilters": []
  },
  "locallyAddedAssertions": {
    "prefixAssertions": [],
    "bgpsecAssertions": []
  }
}
```

#### Example 2: Adding Local ROA Assertions

```json
{
  "slurmVersion": 1,
  "validationOutputFilters": {
    "prefixFilters": [],
    "bgpsecFilters": []
  },
  "locallyAddedAssertions": {
    "prefixAssertions": [
      {
        "prefix": "198.51.100.0/24",
        "asn": 64496,
        "maxPrefixLength": 24,
        "comment": "Local override for AS64496"
      }
    ],
    "bgpsecAssertions": []
  }
}
```

### Strict Mode RPKI Validation

For environments requiring stricter RPKI validation, modify the `rpki_check()` function:

```
function rpki_check_strict() {
  case roa_check(rpki_table, net, bgp_path.last) {
    ROA_VALID: {
      # Add community to mark route as RPKI valid
      bgp_community.add((${OUR_AS}, 1001));
      print "RPKI: Valid route: ", net, " ASN: ", bgp_path.last;
      accept;
    }
    ROA_UNKNOWN, ROA_INVALID: {
      # Reject both unknown and invalid in strict mode
      bgp_community.add((${OUR_AS}, 1000));
      print "RPKI: Rejected route (strict mode): ", net, " ASN: ", bgp_path.last;
      reject;
    }
  }
}
```

## Troubleshooting RPKI Validation

### Common Issues and Solutions

1. **Routinator fails to start**
   ```bash
   # Check logs for errors
   journalctl -u routinator -n 50
   
   # Verify TAL files exist
   ls -la /var/lib/routinator/tals/
   
   # Reinitialize Routinator
   routinator init --force --accept-arin-rpa
   ```

2. **No ROAs in RPKI table**
   ```bash
   # Check if Routinator has ROAs
   routinator vrps stats
   
   # Force refresh of RPKI data
   routinator refresh
   
   # Verify RTR protocol is working
   nc -v localhost 8323
   ```

3. **BIRD doesn't connect to Routinator**
   ```bash
   # Check BIRD logs
   grep "rpki" /var/log/syslog
   
   # Verify RPKI protocol configuration in BIRD
   birdc show protocols rpki_routinator
   
   # Restart services in correct order
   systemctl restart routinator
   sleep 10
   systemctl restart bird
   ```

## Safety Measures

1. Always start with the conservative approach to RPKI validation before moving to strict mode
2. Monitor carefully for the first few days after enabling RPKI validation
3. Consider setting up alerts for RPKI validation failures
4. Regularly check ROA coverage for your own prefixes
5. Keep a local backup of the SLURM file