#\!/usr/bin/env python3

import json
import os
import sys

def load_config(config_file):
    """Load the BGP configuration from a JSON file."""
    try:
        with open(config_file, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading configuration: {e}")
        sys.exit(1)

def generate_static_config(config):
    """Generate the static routes configuration file."""
    template = config["templates"]["static_routes"]
    
    # Replace template variables
    ipv4_prefix = config["global"]["announcements"]["ipv4"][0]
    ipv6_prefix = config["global"]["announcements"]["ipv6"][0]
    
    static_config = template.replace("{IPV4_PREFIX}", ipv4_prefix)
    static_config = static_config.replace("{IPV6_PREFIX}", ipv6_prefix)
    
    return static_config

def generate_vultr_config(config, node_name):
    """Generate the Vultr BGP configuration file for a specific node."""
    template = config["templates"]["vultr_bgp"]
    node = config["nodes"][node_name]
    
    # Replace template variables
    vultr_config = template.replace("{VULTR_ASN}", str(config["global"]["vultr_asn"]))
    vultr_config = vultr_config.replace("{OUR_ASN}", str(config["global"]["our_asn"]))
    vultr_config = vultr_config.replace("{VULTR_IP}", node["vultr_ip"])
    vultr_config = vultr_config.replace("{VULTR_IPV4_NEIGHBOR}", config["global"]["vultr_bgp"]["ipv4_neighbor"])
    vultr_config = vultr_config.replace("{VULTR_IPV6_NEIGHBOR}", config["global"]["vultr_bgp"]["ipv6_neighbor"])
    vultr_config = vultr_config.replace("{VULTR_MULTIHOP}", str(config["global"]["vultr_bgp"]["multihop"]))
    vultr_config = vultr_config.replace("{VULTR_PASSWORD}", config["global"]["vultr_bgp"]["password"])
    vultr_config = vultr_config.replace("{IPV4_PREFIX}", config["global"]["announcements"]["ipv4"][0])
    vultr_config = vultr_config.replace("{IPV6_PREFIX}", config["global"]["announcements"]["ipv6"][0])
    
    return vultr_config

def generate_ibgp_config(config, node_name):
    """Generate the iBGP configuration file for a specific node."""
    node = config["nodes"][node_name]
    
    if node["is_route_reflector"]:
        template = config["templates"]["ibgp_rr"]
        
        # Replace template variables
        ibgp_config = template.replace("{OUR_ASN}", str(config["global"]["our_asn"]))
        ibgp_config = ibgp_config.replace("{LAX_IP}", config["nodes"]["lax"]["vultr_ip"])
        ibgp_config = ibgp_config.replace("{ORD_IP}", config["nodes"]["ord"]["vultr_ip"])
        ibgp_config = ibgp_config.replace("{MIA_IP}", config["nodes"]["mia"]["vultr_ip"])
        ibgp_config = ibgp_config.replace("{EWR_IP}", config["nodes"]["ewr"]["vultr_ip"])
    else:
        template = config["templates"]["ibgp_client"]
        
        # Replace template variables
        ibgp_config = template.replace("{OUR_ASN}", str(config["global"]["our_asn"]))
        ibgp_config = ibgp_config.replace("{NODE_NAME}", node_name)
        ibgp_config = ibgp_config.replace("{NODE_NAME_UPPER}", node_name.upper())
        ibgp_config = ibgp_config.replace("{VULTR_IP}", node["vultr_ip"])
        ibgp_config = ibgp_config.replace("{LAX_IP}", config["nodes"]["lax"]["vultr_ip"])
    
    return ibgp_config

def generate_bird_config(config, node_name):
    """Generate the main BIRD configuration file for a specific node."""
    template = config["templates"]["bird_base"]
    node = config["nodes"][node_name]
    
    # Replace template variables
    bird_config = template.replace("{NODE_NAME}", node_name.upper())
    bird_config = bird_config.replace("{NODE_ROLE}", node["role"])
    bird_config = bird_config.replace("{VULTR_IP}", node["vultr_ip"])
    
    return bird_config

def generate_all_configs(config, node_name, output_dir):
    """Generate all configuration files for a specific node and save them to the output directory."""
    # Create output directory if it doesn't exist
    node_dir = os.path.join(output_dir, node_name)
    os.makedirs(node_dir, exist_ok=True)
    
    # Generate configurations
    static_config = generate_static_config(config)
    vultr_config = generate_vultr_config(config, node_name)
    ibgp_config = generate_ibgp_config(config, node_name)
    bird_config = generate_bird_config(config, node_name)
    
    # Write configurations to files
    with open(os.path.join(node_dir, "static.conf"), "w") as f:
        f.write(static_config)
    
    with open(os.path.join(node_dir, "vultr.conf"), "w") as f:
        f.write(vultr_config)
    
    with open(os.path.join(node_dir, "ibgp.conf"), "w") as f:
        f.write(ibgp_config)
    
    with open(os.path.join(node_dir, "bird.conf"), "w") as f:
        f.write(bird_config)
    
    print(f"Generated configurations for {node_name} in {node_dir}")

def main():
    if len(sys.argv) < 2:
        print("Usage: generate_configs.py <config_file> [node_name]")
        sys.exit(1)
    
    config_file = sys.argv[1]
    node_name = sys.argv[2] if len(sys.argv) > 2 else None
    
    config = load_config(config_file)
    output_dir = "generated_configs"
    
    if node_name:
        if node_name in config["nodes"]:
            generate_all_configs(config, node_name, output_dir)
        else:
            print(f"Error: Node '{node_name}' not found in configuration")
            sys.exit(1)
    else:
        # Generate configurations for all nodes
        for node_name in config["nodes"]:
            generate_all_configs(config, node_name, output_dir)

if __name__ == "__main__":
    main()
