#!/usr/bin/env python3
"""
BGP Mesh Service Discovery API
Provides node configuration, WireGuard configs, and firewall rules
"""

import json
import sys
from datetime import datetime
from flask import Flask, jsonify, request
from pathlib import Path

app = Flask(__name__)

# Load service discovery configuration
CONFIG_FILE = Path(__file__).parent / "service-discovery-schema.json"

def load_config():
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def get_node_by_region(region):
    """Get node configuration by region"""
    config = load_config()
    for node_id, node_config in config["wireguard_config"]["node_assignments"].items():
        if node_config["region"] == region:
            return node_id, node_config
    return None, None

def get_node_by_vultr_ip(vultr_ip):
    """Get node configuration by Vultr endpoint IP"""
    config = load_config()
    for node_id, node_config in config["wireguard_config"]["node_assignments"].items():
        endpoint_ip = node_config["vultr_endpoint"].split(":")[0]
        if endpoint_ip == vultr_ip:
            return node_id, node_config
    return None, None

@app.route('/api/v1/nodes/<region>/config', methods=['GET'])
def get_node_config(region):
    """Get complete node configuration for a region"""
    node_id, node_config = get_node_by_region(region)
    
    if not node_config:
        return jsonify({"error": f"No node found for region {region}"}), 404
    
    config = load_config()
    geographic_config = config["network_allocation"]["geographic_allocation"].get(region, {})
    
    response = {
        "node_id": node_id,
        "region": region,
        "role": node_config["role"],
        "announced_ip": node_config["announced_ip"],
        "anycast_ip": config["network_allocation"]["anycast_config"]["global_service_ip"],
        "wireguard": {
            "ipv4": node_config["ipv4"],
            "ipv6": node_config["ipv6"],
            "private_key": node_config["private_key"],
            "port": config["wireguard_config"]["mesh_networks"]["port"]
        },
        "geographic_allocation": geographic_config,
        "bgp_config": config["bgp_config"]["global"],
        "service_ports": {
            "anycast": config["network_allocation"]["anycast_config"]["service_ports"],
            "looking_glass": config["service_specific"]["looking_glass_port"],
            "bgp": config["service_specific"]["bgp_port"]
        }
    }
    
    return jsonify(response)

@app.route('/api/v1/nodes/<node_id>/wireguard', methods=['GET'])
def get_wireguard_config(node_id):
    """Get WireGuard configuration for a specific node"""
    config = load_config()
    wg_config = config["wireguard_config"]
    
    if node_id not in wg_config["node_assignments"]:
        return jsonify({"error": f"Node {node_id} not found"}), 404
    
    node = wg_config["node_assignments"][node_id]
    mesh_config = wg_config["mesh_networks"]
    
    # Build peer list (all nodes except self)
    peers = []
    for peer_id, peer_config in wg_config["node_assignments"].items():
        if peer_id != node_id:
            peers.append({
                "public_key": peer_config["public_key"],
                "endpoint": peer_config["vultr_endpoint"],
                "allowed_ips": [
                    f"{peer_config['ipv4']}/32",
                    f"{peer_config['ipv6']}/128"
                ],
                "persistent_keepalive": mesh_config["keepalive"],
                "description": f"{peer_id.upper()} {peer_config['role']}"
            })
    
    response = {
        "interface": {
            "private_key": node["private_key"],
            "address": [
                f"{node['ipv4']}/24",
                f"{node['ipv6']}/64"
            ],
            "listen_port": mesh_config["port"]
        },
        "peers": peers
    }
    
    return jsonify(response)

@app.route('/api/v1/firewall/rules', methods=['GET'])
def get_firewall_rules():
    """Get firewall rules configuration"""
    config = load_config()
    return jsonify(config["firewall_config"])

@app.route('/api/v1/nodes/discover', methods=['POST'])
def discover_node():
    """Auto-discover node configuration based on external IP"""
    data = request.get_json()
    external_ip = data.get('external_ip')
    
    if not external_ip:
        return jsonify({"error": "external_ip required"}), 400
    
    node_id, node_config = get_node_by_vultr_ip(external_ip)
    
    if not node_config:
        return jsonify({"error": f"No node found for IP {external_ip}"}), 404
    
    return get_node_config(node_config["region"])

@app.route('/api/v1/status', methods=['GET'])
def get_status():
    """Get service discovery API status"""
    config = load_config()
    return jsonify({
        "service": config["service_info"]["name"],
        "version": config["service_info"]["version"],
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "total_nodes": len(config["wireguard_config"]["node_assignments"]),
        "anycast_ip": config["network_allocation"]["anycast_config"]["global_service_ip"]
    })

@app.route('/api/v1/nodes/<node_id>/cloud-init', methods=['GET'])
def get_cloud_init_config(node_id):
    """Generate cloud-init configuration for a node"""
    config = load_config()
    wg_config = config["wireguard_config"]
    
    if node_id not in wg_config["node_assignments"]:
        return jsonify({"error": f"Node {node_id} not found"}), 404
    
    node = wg_config["node_assignments"][node_id]
    
    # Generate WireGuard configuration
    wg_interface = f"""[Interface]
PrivateKey = {node['private_key']}
Address = {node['ipv4']}/24, {node['ipv6']}/64
ListenPort = {wg_config['mesh_networks']['port']}

"""
    
    # Add peers
    for peer_id, peer_config in wg_config["node_assignments"].items():
        if peer_id != node_id:
            wg_interface += f"""[Peer]
# {peer_id.upper()}
PublicKey = {peer_config['public_key']}
Endpoint = {peer_config['vultr_endpoint']}
AllowedIPs = {peer_config['ipv4']}/32, {peer_config['ipv6']}/128
PersistentKeepalive = {wg_config['mesh_networks']['keepalive']}

"""
    
    response = {
        "node_id": node_id,
        "region": node["region"],
        "role": node["role"],
        "announced_ip": node["announced_ip"],
        "anycast_ip": config["network_allocation"]["anycast_config"]["global_service_ip"],
        "wireguard_config": wg_interface,
        "dummy_interface_commands": [
            "ip link add dev dummy0 type dummy",
            "ip link set dummy0 up",
            f"ip addr add {node['announced_ip']}/32 dev dummy0",
            f"ip addr add {config['network_allocation']['anycast_config']['global_service_ip']}/32 dev dummy0"
        ]
    }
    
    return jsonify(response)

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'test':
        # Test the API with sample queries
        with app.test_client() as client:
            print("Testing Service Discovery API...")
            
            # Test status
            print("\n1. API Status:")
            response = client.get('/api/v1/status')
            print(json.dumps(response.get_json(), indent=2))
            
            # Test node config
            print("\n2. LAX Node Config:")
            response = client.get('/api/v1/nodes/lax/config')
            print(json.dumps(response.get_json(), indent=2))
            
            # Test WireGuard config
            print("\n3. ORD WireGuard Config:")
            response = client.get('/api/v1/nodes/ord/wireguard')
            print(json.dumps(response.get_json(), indent=2))
            
            # Test discovery
            print("\n4. Node Discovery:")
            response = client.post('/api/v1/nodes/discover', 
                                 json={"external_ip": "149.248.2.74"})
            print(json.dumps(response.get_json(), indent=2))
    else:
        # Run the API server
        app.run(host='0.0.0.0', port=5000, debug=True)