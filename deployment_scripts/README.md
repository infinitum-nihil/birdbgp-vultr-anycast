# Deployment Scripts

This directory contains scripts used for deploying BGP configurations to different servers.

## Scripts

- **deploy_all_servers.sh**: Deploys BGP configuration to all servers
- **deploy_lax_only.sh**: Deploys configuration to LAX server only
- **deploy_temp.sh**: Current working deployment script
- **fix_deploy_temp.sh**: Script to fix deployment issues

## Usage

The main deployment script is `deploy_temp.sh`. Other scripts are either specialized versions or support scripts.

## Note
These scripts handle the core deployment of BGP configurations. They should be used with caution and tested in a staging environment first. 