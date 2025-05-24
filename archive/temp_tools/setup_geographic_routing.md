# Geographic BGP Looking Glass Routing

## Current Issue
Right now all looking glass queries go to LAX (149.248.2.74), but users should be routed to their geographically closest BGP node for better performance.

## Proposed Solution: GeoDNS or Load Balancer

### Option 1: DNS-Based Geographic Routing
```
lg.infinitum-nihil.com -> Routes to closest node based on user location
- East Coast users    -> EWR (Newark) 66.135.18.138
- Southeast users     -> MIA (Miami) 149.28.108.180  
- Midwest users       -> ORD (Chicago) 66.42.113.101
- West Coast users    -> LAX (Los Angeles) 149.248.2.74
```

### Option 2: Anycast HTTP
Use the anycast IP (192.30.120.10) for the looking glass:
- All nodes serve looking glass on 192.30.120.10:80
- BGP routing automatically directs users to closest node
- Requires looking glass deployment on all 4 nodes

### Current Node Status
- LAX: ✅ Looking glass operational
- ORD: ❌ Need to deploy looking glass  
- MIA: ❌ Need to deploy looking glass
- EWR: ❌ Need to deploy looking glass

## Implementation Steps

### Phase 1: Deploy Looking Glass on All Nodes
1. Copy working-lg.php to all nodes
2. Configure nginx on all nodes  
3. Test local BIRD connectivity on each node

### Phase 2: Anycast HTTP Setup  
1. Configure all nodes to serve on 192.30.120.10:80
2. Update DNS to point lg.infinitum-nihil.com -> 192.30.120.10
3. Test geographic routing

### Phase 3: Node-Specific Customization
Update each looking glass to show:
- Local node identifier (LAX/ORD/MIA/EWR)
- Local BGP status and routes
- Geographic location information

## Benefits
- Better performance for users (lower latency to closest node)
- Redundancy (if one node fails, others still serve looking glass)
- Load distribution across the mesh network
- True utilization of the anycast infrastructure