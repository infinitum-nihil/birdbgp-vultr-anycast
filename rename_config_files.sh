#!/bin/bash

cd config_files

# Backup original files
mkdir -p backup
cp *.txt backup/

# Rename server IP files with new hierarchical naming scheme
mv server_lax_ipv4.txt US-WEST-LAX-BGP-IPV4.txt
mv server_lax_ipv6.txt US-WEST-LAX-BGP-IPV6.txt
mv server_ewr_ipv4.txt US-EAST-EWR-BGP-IPV4.txt
mv server_mia_ipv4.txt US-EAST-MIA-BGP-IPV4.txt
mv server_ord_ipv4.txt US-CENTRAL-ORD-BGP-IPV4.txt

# Rename authentication file to match scheme
mv auth_vultr_ssh_key.txt GLOBAL-AUTH-VULTR-SSH.txt

# Update README.md
cat > README.md << 'EOF'
# Essential Configuration Files

This directory contains critical configuration files needed for the BGP setup.

## Files

### Server IP Addresses
Format: `{REGION}-{LOCATION}-BGP-{PROTOCOL}.txt`

#### US West Region
- **US-WEST-LAX-BGP-IPV4.txt**: Los Angeles IPv4 address (Primary)
- **US-WEST-LAX-BGP-IPV6.txt**: Los Angeles IPv6 address (Primary)

#### US East Region
- **US-EAST-EWR-BGP-IPV4.txt**: New Jersey IPv4 address (Secondary)
- **US-EAST-MIA-BGP-IPV4.txt**: Miami IPv4 address (Tertiary)

#### US Central Region
- **US-CENTRAL-ORD-BGP-IPV4.txt**: Chicago IPv4 address (Quaternary)

### Authentication
Format: `{SCOPE}-{TYPE}-{PROVIDER}-{METHOD}.txt`

- **GLOBAL-AUTH-VULTR-SSH.txt**: Vultr SSH key ID for server authentication

## Usage
These files contain essential configuration data used by the deployment scripts. They should be backed up and handled securely.

## Naming Convention
- **REGION**: Geographical region (US-WEST, US-EAST, US-CENTRAL, etc.)
- **LOCATION**: IATA airport code for the city (LAX, EWR, MIA, ORD)
- **BGP**: Indicates BGP server configuration
- **PROTOCOL**: Network protocol (IPV4, IPV6)

## Note
- Do not modify these files manually unless absolutely necessary
- Always keep backups of these files
- These files contain sensitive information and should be handled securely
- Original files are preserved in the backup/ directory
EOF

echo "Configuration files have been renamed with the new hierarchical naming scheme."
echo "Original files are backed up in config_files/backup/"
echo "Please update any scripts that reference these filenames." 