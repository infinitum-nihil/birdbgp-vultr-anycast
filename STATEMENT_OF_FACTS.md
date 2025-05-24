# STATEMENT OF FACTS

## SSH Keys
- The SSH key to use for ALL connections is `/home/normtodd/.ssh/id_ed25519_nt_infinitum-nihil_com`
- This key is associated with the email address `nt@infinitum-nihil.com`
- NEVER use `/home/normtodd/.ssh/id_rsa` or any other key

## BGP Speaker Hierarchy
- Primary BGP speaker: LAX (Los Angeles) - 149.248.2.74
- Secondary BGP speaker: ORD (Chicago) - 66.42.113.101 (closest to LA)
- Tertiary BGP speaker: MIA (Miami) - 149.28.108.180 (farther from LA)
- Quaternary BGP speaker: EWR (Newark) - 66.135.18.138 (farthest from LA)

## Network Configuration
- Router ID must be the external/public IP address, NOT an internal IP
- WireGuard IP addresses:
  - LAX: 10.10.10.1
  - ORD: 10.10.10.2
  - MIA: 10.10.10.3
  - EWR: 10.10.10.4
- BGP connections use TCP port 179
- WireGuard connections use UDP port 51820
- ICMP must be allowed between all nodes
- BIRD2 must be installed from source (most recent found on https://bird.network.cz), NOT from package repositories
- ARIN assigned IP blocks that must be announced:
  - IPv4: 192.30.120.0/23
  - IPv6: 2620:71:4000::/48

## Firewall Rules
- UFW and Vultr firewall must both be properly configured
- Allow ICMP traffic between all nodes
- Allow TCP port 179 (BGP) between all nodes
- Allow UDP port 51820 (WireGuard) between all nodes
- Allow all traffic on the WireGuard interface (wg0)

## BGP Configuration
- All nodes are in the same AS: 27218
- LAX serves as the route reflector for the mesh network
- All other nodes connect to LAX as BGP clients
- All nodes must use their EXTERNAL/PUBLIC IP for router ID and BGP peering, NOT WireGuard IPs
- All nodes must peer with Vultr using:
  - Vultr ASN: 64515
  - Neighbor: 169.254.169.254 (IPv4) and 2001:19f0:ffff::1 (IPv6)
  - BGP password: xV72GUaFMSYxNmee
  - Multihop: 2

## Vultr API
- API Key: [REDACTED - Load from environment variable VULTR_API_KEY]
- Proper API call format:
```bash
curl "https://api.vultr.com/v2/endpoint" \
  -X POST \
  -H "Authorization: Bearer ${VULTR_API_KEY}" \
  -H "Content-Type: application/json" \
  --data '{
    "key": "value"
  }'
```