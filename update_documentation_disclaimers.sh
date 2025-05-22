#!/bin/bash
# Script to update all educational MD files with a date and disclaimer

# Exit on any error
set -e

# Current date in YYYY-MM-DD format
CURRENT_DATE=$(date +"%B %d, %Y")

# Get the disclaimer template
DISCLAIMER=$(cat "support docs/disclaimer_template.md" | sed "s/May 22, 2025/$CURRENT_DATE/g")

# List of educational documentation files to update
DOCS=(
  "support docs/rpki-setup.md"
  "support docs/bgp-communities.md"
  "support docs/rpki-aspa.md"
  "support docs/security.md"
  "support docs/deploysteps.md"
  "README.md"
  "SECURITY.md"
)

# Function to add disclaimer to a file
add_disclaimer() {
  local file="$1"
  local temp_file=$(mktemp)
  
  echo "Updating $file with disclaimer and date..."
  
  # Read file content
  cat "$file" > "$temp_file"
  
  # Add disclaimer at the top of the file
  echo "$DISCLAIMER" > "$file"
  cat "$temp_file" >> "$file"
  
  # Clean up
  rm "$temp_file"
  
  echo "Updated $file successfully"
}

# Main loop
for doc in "${DOCS[@]}"; do
  if [ -f "$doc" ]; then
    add_disclaimer "$doc"
  else
    echo "Warning: File $doc not found, skipping..."
  fi
done

echo "All documentation files have been updated with disclaimers and dates"