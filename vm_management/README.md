# VM Management Scripts

This directory contains scripts for managing Vultr VM instances and their configurations.

## Scripts

- **check_vms.sh**: Checks the status of VM instances
- **get_instances.sh**: Retrieves information about VM instances
- **list_instances.sh**: Lists all VM instances
- **list_bgp_instances.sh**: Lists instances with BGP enabled
- **restart_vms.sh**: Handles VM restart operations
- **update_hostnames.sh**: Updates VM hostnames

## Usage

These scripts are used for managing the lifecycle and configuration of VM instances. They interact with the Vultr API to perform various management tasks.

## Note
VM management operations can affect service availability. Use these scripts with caution and during maintenance windows when possible. 