#!/bin/bash
# cleanup_before_commit.sh - Cleans up files before commit

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Starting cleanup of unnecessary files...${NC}"

# Remove old .txt files
echo -e "${YELLOW}Removing old .txt files...${NC}"
find /home/normtodd/birdbgp/archived_files -type f -name "*.txt" -exec rm -v {} \;
find /home/normtodd/birdbgp/artifacts_archive -type f -name "*.txt" -exec rm -v {} \;
find /home/normtodd/birdbgp/config_files/backup -type f -name "*.txt" -exec rm -v {} \;
rm -vf /home/normtodd/birdbgp/lax-ipv4_floating_ip.txt

# Remove 'tobedeleted' directory
echo -e "${YELLOW}Removing 'tobedeleted' directory...${NC}"
rm -rf /home/normtodd/birdbgp/tobedeleted

# Remove log files (excluding the most recent ones)
echo -e "${YELLOW}Removing old log files...${NC}"
find /home/normtodd/birdbgp -type f -name "*.log" -mtime +7 -exec rm -v {} \;

# Remove .bak files in remaining_backup
echo -e "${YELLOW}Removing .bak files in remaining_backup...${NC}"
find /home/normtodd/birdbgp/remaining_backup -type f -name "*.bak" -exec rm -v {} \;

# Clean up redundant script backups
echo -e "${YELLOW}Cleaning up redundant script backups...${NC}"
rm -vf /home/normtodd/birdbgp/remaining_backup/new_docker_compose.yml.bak

# Check if there are any duplicate scripts in archived_scripts that exist in main directory
echo -e "${YELLOW}Checking for duplicate scripts...${NC}"
for file in /home/normtodd/birdbgp/archived_scripts/*.sh; do
    basename=$(basename "$file")
    if [ -f "/home/normtodd/birdbgp/$basename" ]; then
        echo -e "${RED}Found duplicate: $basename${NC}"
        # Don't delete automatically, just report
    fi
done

echo -e "${GREEN}Cleanup completed!${NC}"