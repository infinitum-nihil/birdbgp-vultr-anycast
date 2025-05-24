# Archive Directory

This directory contains historical scripts and configurations that are no longer needed for the current production BGP anycast mesh deployment.

## Directory Structure

- **legacy_deployment/**: Old deployment methods before service discovery
- **manual_fixes/**: Manual fix scripts replaced by automation  
- **testing_scripts/**: Development and testing tools
- **temp_tools/**: One-time use scripts and temporary files
- **hyperglass_backup/**: Looking glass deployment experiments

## Current Production Scripts

The production deployment now uses only these essential scripts in the root directory:

- `deploy_production_mesh.sh`: Main deployment orchestration
- `manual_bootstrap.sh`: Manual node configuration when needed
- `readystatuscheck.sh`: Instance readiness monitoring

All other functionality is handled by:

- Service Discovery API (`service-discovery-api.py`)
- Cloud-init automation (`cloud-init-with-service-discovery.yaml`)
- BIRD configuration templates (`bird-*-correct.conf`)

These archived scripts are kept for historical reference and learning purposes.
