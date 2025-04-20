#!/bin/bash

# Check if python3 and jsonschema are installed
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required but not installed"
    exit 1
fi

if ! python3 -c "import jsonschema" &> /dev/null; then
    echo "Installing jsonschema package..."
    pip3 install jsonschema
fi

# Validate the configuration
python3 -c "
import json
import jsonschema
from jsonschema import validate

# Load the schema
with open('bgp_cloud_config.schema.json', 'r') as f:
    schema = json.load(f)

# Load the configuration
with open('bgp_cloud_config.json', 'r') as f:
    config = json.load(f)

# Validate
try:
    validate(instance=config, schema=schema)
    print('Configuration is valid!')
except jsonschema.exceptions.ValidationError as e:
    print('Configuration validation failed:')
    print(e.message)
    exit(1)
" 