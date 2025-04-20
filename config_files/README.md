# Configuration Management

This directory contains the configuration for BGP servers and authentication details. The configuration is stored in a structured JSON format for better maintainability and validation.

## Configuration Structure

The main configuration file is `config.json`, which follows this structure:

```json
{
  "version": "1.0.0",
  "last_updated": "YYYY-MM-DD",
  "servers": {
    "us-west": {
      "lax": {
        "ipv4": {
          "address": "IP_ADDRESS",
          "role": "primary",
          "last_updated": "YYYY-MM-DD"
        },
        "ipv6": {
          "address": "IPV6_ADDRESS",
          "role": "primary",
          "last_updated": "YYYY-MM-DD"
        }
      }
    },
    "us-east": {
      "ewr": {
        "ipv4": {
          "address": "IP_ADDRESS",
          "role": "secondary",
          "last_updated": "YYYY-MM-DD"
        }
      },
      "mia": {
        "ipv4": {
          "address": "IP_ADDRESS",
          "role": "tertiary",
          "last_updated": "YYYY-MM-DD"
        }
      }
    },
    "us-central": {
      "ord": {
        "ipv4": {
          "address": "IP_ADDRESS",
          "role": "quaternary",
          "last_updated": "YYYY-MM-DD"
        }
      }
    }
  },
  "authentication": {
    "vultr": {
      "ssh_key_id": "KEY_ID",
      "last_rotated": "YYYY-MM-DD"
    }
  },
  "metadata": {
    "schema_version": "1.0.0",
    "maintainer": "System Administrator",
    "description": "BGP server configuration and authentication details"
  }
}
```

## Migration from Text Files

The original text-based configuration files have been migrated to this JSON structure. The migration script `migrate_to_json.sh` was used to perform this conversion. Original files are preserved in the `backup/` directory.

## Security Practices

### File Handling
1. **Access Control**
   - Restrict file permissions to necessary users only
   - Use `chmod 600` for sensitive files
   - Maintain a log of file access and modifications

2. **Backup Procedures**
   - Regular backups should be maintained
   - Backup files should follow the same security protocols as primary files
   - Use version control for configuration history (excluding sensitive data)

3. **Modification Guidelines**
   - Document all changes in a changelog
   - Verify file integrity after modifications
   - Test configurations before deployment
   - Use JSON schema validation before committing changes

### Best Practices
- Never commit sensitive data to version control
- Use encryption for file storage and transfer
- Regularly rotate authentication keys
- Monitor file access and modifications
- Maintain an audit trail of all changes
- Use JSON schema validation for configuration changes

## Usage

### Reading Configuration
```bash
# Using jq to read specific values
jq '.servers["us-west"].lax.ipv4.address' config.json
jq '.authentication.vultr.ssh_key_id' config.json
```

### Modifying Configuration
1. Make changes to `config.json`
2. Validate the JSON structure:
   ```bash
   jq . config.json > /dev/null
   ```
3. Test the configuration
4. Commit the changes

## Note
- Do not modify the configuration manually unless absolutely necessary
- Always keep backups of the configuration
- The configuration contains sensitive information and should be handled securely
- Any modifications should be documented and tested before deployment
- Use the provided scripts for configuration management
