#!/usr/bin/env python3
"""
Enhanced BGP Mesh Service Discovery API with Geographic Intelligence
Provides node configuration, WireGuard configs, and firewall rules
"""

import json
import sys
import os
import requests
from datetime import datetime
from flask import Flask, jsonify, request
from pathlib import Path

app = Flask(__name__)

# Load service discovery configuration
CONFIG_FILE = Path(__file__).parent / "service-discovery-schema.json"
VULTR_API_KEY = os.environ.get('VULTR_API_KEY', 'OOBGITQGHOKATE5WMUYXCKE3UTA5O6OW4ENQ')

# Allowed source IPs for API access (our BGP mesh + local management)
ALLOWED_IPS = {
    '149.248.2.74',    # LAX
    '45.76.18.21',     # ORD  
    '45.77.192.217',   # MIA
    '149.28.56.192',   # EWR
    '127.0.0.1',       # Local
    '10.10.10.1',      # LAX WireGuard
    '10.10.10.2',      # ORD WireGuard  
    '10.10.10.3',      # MIA WireGuard
    '10.10.10.4'       # EWR WireGuard
}

def check_access():
    """Check if the requesting IP is allowed"""
    client_ip = request.environ.get('HTTP_X_FORWARDED_FOR', request.environ.get('REMOTE_ADDR', ''))
    if client_ip.split(',')[0].strip() not in ALLOWED_IPS:
        return False
    return True

def get_vultr_instance_region(ip_address):
    """Get the actual Vultr region for an IP address using Vultr API"""
    try:
        headers = {'Authorization': f'Bearer {VULTR_API_KEY}'}
        response = requests.get('https://api.vultr.com/v2/instances', headers=headers, timeout=10)
        if response.status_code == 200:
            instances = response.json().get('instances', [])
            for instance in instances:
                if instance.get('main_ip') == ip_address:
                    return instance.get('region')
    except Exception as e:
        print(f"Error querying Vultr API: {e}")
    return None

def find_geographic_slot(external_ip, config):
    """Find the correct geographic slot for an IP based on Vultr region"""
    # Get the actual region from Vultr API
    vultr_region = get_vultr_instance_region(external_ip)
    
    if not vultr_region:
        return None
        
    # Map Vultr regions to our node IDs
    region_mapping = {
        'lax': 'lax',
        'ord': 'ord', 
        'mia': 'mia',
        'ewr': 'ewr'
    }
    
    target_node_id = region_mapping.get(vultr_region)
    if not target_node_id:
        return None
        
    # Check if this geographic slot is available
    node_config = config['wireguard_config']['node_assignments'].get(target_node_id)
    if node_config:
        current_endpoint_ip = node_config['vultr_endpoint'].split(':')[0]
        # If slot is available or has placeholder IP
        if current_endpoint_ip in ['0.0.0.0', '45.76.21.14', '207.246.118.124', '45.77.206.132']:
            return target_node_id
            
    return None

def load_config():
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def save_config(config):
    """Save updated configuration to file"""
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=2)

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

@app.before_request
def limit_remote_addr():
    """Firewall check before processing any request"""
    if not check_access():
        return jsonify({'error': 'Access denied: IP not authorized'}), 403

@app.route('/api/v1/nodes/register', methods=['POST'])
def register_node():
    """
    Geographic-aware node self-registration endpoint.
    Uses Vultr API to determine correct geographic assignment.
    """
    try:
        data = request.get_json()
        external_ip = data.get('external_ip')
        external_ipv6 = data.get('external_ipv6', '')
        
        if not external_ip:
            return jsonify({'error': 'external_ip required'}), 400
        
        # Load current config
        config = load_config()
        
        # Check if this IP already exists
        existing_node_id, existing_node = get_node_by_vultr_ip(external_ip)
        
        if existing_node:
            # Update existing node endpoint
            config['wireguard_config']['node_assignments'][existing_node_id]['vultr_endpoint'] = f"{external_ip}:51820"
            save_config(config)
            return jsonify({
                'status': 'updated',
                'node_id': existing_node_id,
                'message': f'Updated endpoint for {existing_node_id}',
                'geographic_region': existing_node['region']
            })
        else:
            # Find correct geographic slot using Vultr API
            geographic_node_id = find_geographic_slot(external_ip, config)
            
            if geographic_node_id:
                config['wireguard_config']['node_assignments'][geographic_node_id]['vultr_endpoint'] = f"{external_ip}:51820"
                save_config(config)
                return jsonify({
                    'status': 'registered',
                    'node_id': geographic_node_id,
                    'message': f'Registered as {geographic_node_id} (geographic match)',
                    'assigned_ip': external_ip,
                    'geographic_region': config['wireguard_config']['node_assignments'][geographic_node_id]['region']
                })
            else:
                return jsonify({'error': 'No geographic slot available or region detection failed'}), 400
            
    except Exception as e:
        return jsonify({'error': f'Registration failed: {str(e)}'}), 500

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
        "anycast_ip": config["network_allocation"]["anycast_config"]["global_service_ip"],
        "firewall_enabled": True,
        "allowed_ips": len(ALLOWED_IPS)
    })

@app.route('/api/v1/admin/reset-geography', methods=['POST'])
def reset_geography():
    """Admin endpoint to reset geographic assignments based on current Vultr data"""
    try:
        config = load_config()
        
        # Get all current assignments that need geographic correction
        corrections_made = []
        
        for node_id, node_config in config['wireguard_config']['node_assignments'].items():
            current_endpoint_ip = node_config['vultr_endpoint'].split(':')[0]
            if current_endpoint_ip != '0.0.0.0':
                correct_region = get_vultr_instance_region(current_endpoint_ip)
                if correct_region and correct_region != node_id:
                    corrections_made.append({
                        'ip': current_endpoint_ip,
                        'wrong_slot': node_id,
                        'correct_slot': correct_region
                    })
        
        return jsonify({
            'status': 'analysis_complete',
            'corrections_needed': corrections_made,
            'message': 'Use /api/v1/admin/fix-geography to apply corrections'
        })
        
    except Exception as e:
        return jsonify({'error': f'Geographic reset failed: {str(e)}'}), 500

if __name__ == '__main__':
    # Run the API server
    app.run(host='0.0.0.0', port=5000, debug=True)