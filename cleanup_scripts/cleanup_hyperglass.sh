#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

echo -e "${BLUE}${BOLD}Cleaning up Hyperglass/Looking Glass references${NC}"
echo "=================================================="

# 1. First ensure all hyperglass and related files are in backup directory
echo -e "\n${BOLD}1. Moving Hyperglass and related files to backup directory${NC}"
mkdir -p hyperglass_backup

# List of files to move (expanded to include all related components)
RELATED_FILES=(
    # Hyperglass core files
    setup_looking_glass.sh
    install_hyperglass.sh
    looking_glass_direct.sh
    setup_full_hyperglass.sh
    pip_hyperglass.sh
    build_hyperglass.sh
    setup_hyperglass.sh
    fix_hyperglass_container.sh
    fix_hyperglass.sh
    build_hyperglass_container.sh
    deploy_hyperglass_lax.sh
    deploy_hyperglass_github.sh
    deploy_hyperglass.sh
    
    # Traefik related files
    update_traefik_config.sh
    fix_traefik_config.sh
    *traefik*.{yml,yaml,conf}
    
    # Web server configs
    *nginx*.conf
    docker-compose*.yml
    
    # Redis related (used by hyperglass)
    fix_redis_connection.sh
    add_redis.sh
    
    # DNS management for looking glass
    dns_create_working.sh
    dns_create_fixed.sh
    dns_create_correct.sh
    dns_fixed_final.sh
    dns_create_with_hex.sh
    create_dns_simplest.sh
    create_dns_fixed.sh
    create_manual_dns.sh
    dns_create_manual.sh
    update_dns_to_floating_ip.sh
    fix_dns_api.sh
    
    # Certificate management (used for HTTPS)
    auto_renew_cert.sh
)

# Move files to backup
for pattern in "${RELATED_FILES[@]}"; do
    mv -f $pattern hyperglass_backup/ 2>/dev/null
done

echo -e "${GREEN}✓ Files moved to hyperglass_backup/${NC}"

# 2. Clean up any remaining DNS scripts
echo -e "\n${BOLD}2. Cleaning remaining DNS configuration scripts${NC}"

# Function to clean up DNS scripts
clean_dns_script() {
    local file=$1
    if [ -f "$file" ]; then
        echo "Cleaning $file..."
        # Create a temporary file
        sed -i.bak \
            -e '/lg\.|looking|glass|hyperglass/d' \
            -e '/traefik/d' \
            -e '/# Create DNS records for looking glass/d' \
            -e '/echo.*Hyperglass/d' \
            -e '/echo.*Looking Glass/d' \
            -e '/dnsmadeeasy.*lg\./d' \
            -e '/DOMAIN.*lg\./d' \
            "$file"
        
        # Remove backup if different
        if cmp -s "$file" "$file.bak"; then
            rm "$file.bak"
            echo -e "${BLUE}No changes needed in $file${NC}"
        else
            echo -e "${GREEN}✓ Cleaned $file${NC}"
            rm "$file.bak"
        fi
    fi
}

# Clean any remaining DNS-related scripts
for script in *dns*.sh; do
    clean_dns_script "$script"
done

# 3. Clean up README.md
echo -e "\n${BOLD}3. Updating README.md${NC}"
if [ -f "README.md" ]; then
    sed -i.bak \
        -e '/hyperglass/Id' \
        -e '/looking glass/Id' \
        -e '/traefik/Id' \
        -e '/redis/Id' \
        -e '/nginx/Id' \
        -e '/web.*interface/Id' \
        -e '/dashboard/Id' \
        "README.md"
    
    if cmp -s "README.md" "README.md.bak"; then
        rm "README.md.bak"
        echo -e "${BLUE}No changes needed in README.md${NC}"
    else
        echo -e "${GREEN}✓ Updated README.md${NC}"
        rm "README.md.bak"
    fi
fi

# 4. Clean up deployment state if it exists
echo -e "\n${BOLD}4. Cleaning deployment state${NC}"
if [ -f "deployment_state.json" ]; then
    # Remove all web/looking glass related states but preserve BGP states
    jq 'del(.hyperglass_deployed, .traefik_deployed, .looking_glass_deployed, .redis_configured, .web_configured, .dns_configured)' \
        deployment_state.json > deployment_state.json.tmp && \
        mv deployment_state.json.tmp deployment_state.json
    echo -e "${GREEN}✓ Cleaned deployment state${NC}"
fi

# 5. Remove any remaining references
echo -e "\n${BOLD}5. Checking for remaining references${NC}"
echo "Searching for any remaining related references..."
remaining=$(grep -r -l -i "hyperglass\|looking.*glass\|traefik\|redis\|nginx\|web.*interface\|dashboard" . \
    --exclude="cleanup_hyperglass.sh" \
    --exclude-dir=".git" \
    --exclude-dir="hyperglass_backup")

if [ -n "$remaining" ]; then
    echo -e "${RED}Found remaining references in:${NC}"
    echo "$remaining"
    echo "Please review these files manually."
else
    echo -e "${GREEN}✓ No remaining references found${NC}"
fi

echo -e "\n${BOLD}Cleanup Complete!${NC}"
echo "=================================================="
echo -e "Backup of removed files is in: ${BLUE}hyperglass_backup/${NC}"
echo -e "Please review changes and test the system."
echo -e "\n${BOLD}Note:${NC} The following components have been removed:"
echo "1. Hyperglass looking glass interface"
echo "2. Traefik reverse proxy"
echo "3. Redis database"
echo "4. Web server configurations"
echo "5. DNS management for web interface"
echo "6. SSL certificate management" 