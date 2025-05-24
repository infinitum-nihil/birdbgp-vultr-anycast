# BGP Anycast Mesh Network with Service Discovery

**Last Updated:** May 24, 2025

## Overview

This project implements a production-ready BGP anycast mesh network across multiple geographic locations using a service discovery architecture. The system provides true anycast routing with automatic geographic load balancing, allowing users to connect to the closest node automatically.

## Key Features

- **Service Discovery Architecture**: Centralized configuration management with RESTful API
- **True Anycast Routing**: Users automatically connect to closest geographic node (192.30.120.10)
- **Dual-Stack IPv4/IPv6**: Complete support for both protocol families with fd00:10:10::/48 mesh
- **WireGuard Mesh**: Secure tunnels for iBGP peering between nodes (10.10.10.0/24)
- **Multi-Provider Ready**: IP allocation strategy supports AWS, GCP, Azure expansion
- **Security-First Design**: Minimal attack surface with strict firewall rules
- **Geographic BGP Looking Glass**: Network diagnostics and routing visibility
- **Cloud-Init Automation**: Self-configuring nodes via service discovery integration

## Network Architecture

### IP Allocation Strategy
```
ASN: 27218 (Infinitum Nihil)
IPv4 Prefix: 192.30.120.0/23 (512 IPs)
IPv6 Prefix: 2620:71:4000::/48
Anycast Service IP: 192.30.120.10 (global load balancing)

Geographic /29 Subnets:
├── LAX: 192.30.120.0/29   (.1=Vultr, .2=Future, .3=AWS, .4=GCP)
├── ORD: 192.30.120.8/29   (.9=Vultr, .10=Future, .11=AWS, .12=GCP)  
├── EWR: 192.30.120.16/29  (.17=Vultr, .18=Future, .19=AWS, .20=GCP)
├── MIA: 192.30.120.24/29  (.25=Vultr, .26=Future, .27=AWS, .28=GCP)
└── Future regions: .32/29, .40/29, etc.
```

### BGP Route Reflector Topology
```
                    LAX (Route Reflector)
                  192.30.120.1 / 10.10.10.1
                         │
              ┌──────────┼──────────┐
              │          │          │
           ORD          MIA        EWR
     192.30.120.9  192.30.120.25  192.30.120.17
      10.10.10.2    10.10.10.3     10.10.10.4
       (Client)      (Client)      (Client)
```

### Security Model
**Announced IPs (192.30.120.x):** Minimal attack surface
- Ports 80/443: Public web services (anycast)  
- Port 8080: BGP looking glass (mesh-only access)

**Vultr IPs (Dynamic):** Infrastructure management
- Port 22: Admin SSH (207.231.1.46/32 only)
- Port 179: BGP (Vultr + mesh tunnel IPs only)  
- Port 51820: WireGuard (known mesh nodes only)

## Prerequisites

1. **Vultr Account**: BGP enabled for your ASN with IP ranges approved
2. **API Access**: Vultr API key with full instance management permissions
3. **SSH Key**: ED25519 key associated with nt@infinitum-nihil.com
4. **DNS/Environment**: Service discovery API endpoint accessible to nodes

## Configuration

### Environment Setup
Create a `.env` file with your sensitive configuration:

```bash
# API Credentials (DO NOT COMMIT TO GIT)
VULTR_API_KEY=your_vultr_api_key_here

# BGP Configuration  
OUR_ASN=27218
VULTR_BGP_PASSWORD=your_bgp_password_here

# SSH Configuration
SSH_KEY_PATH=/path/to/your/ssh/private/key
```

### Service Discovery Configuration
The service discovery system uses `service-discovery-schema.json` which contains:

- **Network allocation** with geographic /29 subnets
- **WireGuard configuration** with verified private keys
- **Firewall rules** for security groups
- **BGP configuration** and route filters

## Deployment

### 1. Service Discovery API
Deploy the service discovery API to LAX (or dedicated instance):

```bash
# On LAX node:
cd /opt/bgp-service-discovery
pip3 install flask
python3 service-discovery-api.py &
```

### 2. Production Mesh Deployment
Deploy all nodes with service discovery integration:

```bash
# Set environment
source .env

# Deploy production mesh
./deploy_production_mesh.sh
```

This will:
1. Destroy existing instances (ORD, MIA, EWR)
2. Create new instances with service discovery cloud-init
3. Each node auto-configures via service discovery API
4. Establishes WireGuard mesh and BGP sessions

### 3. Monitor Deployment
```bash
# Check service discovery API
curl http://149.248.2.74:5000/api/v1/status

# Monitor cloud-init progress
ssh root@NEW_NODE_IP 'tail -f /var/log/bgp-node-bootstrap.log'

# Check BGP sessions
ssh root@149.248.2.74 'birdc show protocols'
```

## Service Discovery API

### Core Endpoints
```
GET  /api/v1/nodes/{region}/config     # Complete node configuration
GET  /api/v1/nodes/{node_id}/wireguard # Dynamic WireGuard mesh config  
GET  /api/v1/firewall/rules           # Centralized firewall rules
POST /api/v1/nodes/discover           # Auto-discovery by external IP
GET  /api/v1/status                   # Service health and metrics
```

### Usage Examples
```bash
# Get LAX configuration
curl http://149.248.2.74:5000/api/v1/nodes/lax/config

# Get ORD WireGuard config
curl http://149.248.2.74:5000/api/v1/nodes/ord/wireguard

# Auto-discover node by IP
curl -X POST http://149.248.2.74:5000/api/v1/nodes/discover \
     -H "Content-Type: application/json" \
     -d '{"external_ip": "45.76.29.217"}'
```

## Anycast Traffic Flow

Users connecting to `192.30.120.10` are automatically routed to the closest geographic node:

```
User Request → 192.30.120.10:80/443
     ↓
   BGP Anycast Routing (shortest AS path)
     ↓  
   LAX: 192.30.120.1    (West Coast users)
   ORD: 192.30.120.9    (Central US users)  
   EWR: 192.30.120.17   (East Coast users)
   MIA: 192.30.120.25   (Southeast US users)
```

## Security Features

### BGP Security
- **RPKI/ASPA Compliance**: Route origin and path validation
- **Aggressive Route Filtering**: Only our announced prefixes allowed
- **Encrypted iBGP**: All iBGP sessions over WireGuard tunnels
- **Route Reflector Security**: Centralized with client authentication

### Network Security
- **Firewall Rules**: UFW + Vultr firewall with source-based access control
- **WireGuard Mesh**: Encrypted tunnels between all nodes
- **SSH Hardening**: Key-based authentication from admin IP only
- **Service Isolation**: Announced IPs only serve web traffic

### Operational Security
- **Service Discovery**: Centralized configuration prevents drift
- **Automated Deployment**: Reduces human error in configuration
- **Git Security**: Sensitive data in .env/.gitignore only
- **API Key Management**: Environment-based credential loading

## Monitoring and Troubleshooting

### BGP Status
```bash
# Check BGP sessions on route reflector
ssh root@149.248.2.74 'birdc show protocols all'

# Check routing table
ssh root@149.248.2.74 'birdc show route'

# Verify announced prefixes
ssh root@149.248.2.74 'birdc show route where source = RTS_BGP'
```

### WireGuard Mesh
```bash
# Check WireGuard status
ssh root@NODE_IP 'wg show'

# Test mesh connectivity  
ssh root@149.248.2.74 'ping 10.10.10.2'  # LAX to ORD
ssh root@149.248.2.74 'ping6 fd00:10:10::2'  # IPv6 mesh
```

### Service Discovery
```bash
# API health check
curl http://149.248.2.74:5000/api/v1/status

# Node discovery test
curl -X POST http://149.248.2.74:5000/api/v1/nodes/discover \
     -H "Content-Type: application/json" \
     -d '{"external_ip": "NODE_IP"}'
```

## File Structure

### Core Service Discovery
- `service-discovery-schema.json` - Network configuration and allocation
- `service-discovery-api.py` - RESTful API server
- `cloud-init-with-service-discovery.yaml` - Bootstrap configuration

### Deployment Scripts
- `deploy_production_mesh.sh` - Production deployment with service discovery
- `recreate_bgp_nodes.sh` - Alternative deployment approach

### Configuration Management
- `bgp_config.json` - Legacy configuration (replaced by service discovery)
- `.env` - Sensitive credentials (gitignored)
- `STATEMENT_OF_FACTS.md` - Infrastructure constants

### Documentation
- `BGP_ANYCAST_MESH_STATUS_2025-05-24.md` - Current project status
- `README.md` - This documentation

## Multi-Provider Expansion

The IP allocation strategy supports expansion to additional cloud providers:

```bash
# Add AWS nodes to existing regions
./deploy_aws_nodes.sh --region lax --ip 192.30.120.3

# Add GCP nodes  
./deploy_gcp_nodes.sh --region ord --ip 192.30.120.11

# Add new geographic regions
./expand_regions.sh --region eu --subnet 192.30.120.32/29
```

## License

Copyright (c) 2025 Infinitum Nihil. All rights reserved.

This project is proprietary and confidential. Unauthorized reproduction or distribution is prohibited.

## Security Notice

This repository contains network infrastructure configurations. Ensure:

1. **API keys** are stored in `.env` (gitignored)
2. **Private keys** are not committed to version control
3. **Sensitive configs** use environment variables
4. **Production credentials** are rotated regularly

For security issues, contact: security@infinitum-nihil.com