#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

echo -e "${BLUE}${BOLD}Cleaning up remaining references to removed components${NC}"
echo "=================================================="

# List of files to clean
FILES_TO_CLEAN=(
    "deploy_temp.sh"
    "new_docker_compose.yml"
    "fix_anycast_forwarding.sh"
    "fix_bird_final.sh"
    "deploy_all_servers.sh"
    "fix_socket_permissions.sh"
    "fix_web_access.sh"
    "update_bird_data.sh"
    "deploy_lax_only.sh"
)

# Backup directory
BACKUP_DIR="remaining_backup"
mkdir -p "$BACKUP_DIR"

# Function to clean a file
clean_file() {
    local file=$1
    echo -e "\n${BOLD}Cleaning $file...${NC}"
    
    # Create backup
    cp "$file" "$BACKUP_DIR/${file}.bak"
    
    # Clean based on file type
    case "$file" in
        "deploy_temp.sh")
            # Remove hyperglass, traefik, redis, and web-related sections
            sed -i.tmp \
                -e '/hyperglass/Id' \
                -e '/traefik/Id' \
                -e '/redis/Id' \
                -e '/nginx/Id' \
                -e '/web.*interface/Id' \
                -e '/dashboard/Id' \
                -e '/lets.*encrypt/Id' \
                "$file"
            ;;
            
        "new_docker_compose.yml")
            # Remove the entire file as it's only for web components
            mv "$file" "$BACKUP_DIR/"
            echo -e "${GREEN}Moved $file to backup as it's no longer needed${NC}"
            return
            ;;
            
        "fix_anycast_forwarding.sh")
            # Remove web-related port forwards
            sed -i.tmp \
                -e '/port.*80/d' \
                -e '/port.*443/d' \
                -e '/http/Id' \
                -e '/https/Id' \
                "$file"
            ;;
            
        *)
            # For other files, remove common web-related terms
            sed -i.tmp \
                -e '/hyperglass/Id' \
                -e '/traefik/Id' \
                -e '/redis/Id' \
                -e '/nginx/Id' \
                -e '/web.*interface/Id' \
                -e '/dashboard/Id' \
                -e '/http/Id' \
                -e '/https/Id' \
                "$file"
            ;;
    esac
    
    # Remove temporary files
    rm -f "$file.tmp"
    
    # Check if file was modified
    if cmp -s "$file" "$BACKUP_DIR/${file}.bak"; then
        echo -e "${BLUE}No changes needed in $file${NC}"
    else
        echo -e "${GREEN}✓ Cleaned $file${NC}"
    fi
}

# Process each file
for file in "${FILES_TO_CLEAN[@]}"; do
    if [ -f "$file" ]; then
        clean_file "$file"
    else
        echo -e "${RED}File not found: $file${NC}"
    fi
done

echo -e "\n${BOLD}Cleanup Complete!${NC}"
echo "=================================================="
echo -e "Backup of original files is in: ${BLUE}${BACKUP_DIR}/${NC}"
echo -e "Please review changes and test the system." 