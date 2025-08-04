#!/usr/bin/env bash

# Regenerate HTML files based on existing RPMs in the repository
# This script scans all existing RPMs and updates HTML to show all available versions

set -euo pipefail

# Configuration
REPO_OWNER="${1:-flightctl}"
REPO_NAME="${2:-flightctl}"
INPUT_DIR="$(pwd)"
TEMPLATES_DIR="$INPUT_DIR/templates"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Template substitution function using temporary files for safe handling
substitute_template() {
    local template_file="$1"
    local output_file="$2"
    shift 2
    
    # Copy template to output
    cp "$template_file" "$output_file"
    
    # Apply substitutions passed as key=value pairs
    while [ $# -gt 0 ]; do
        local key_value="$1"
        # Extract key as everything before the first =
        local key="${key_value%%=*}"
        # Extract value as everything after the first =
        local value="${key_value#*=}"
        
        # Handle special case where value is a file reference
        local temp_value_file
        local cleanup_temp_file=false
        if [[ "$key" == *"_FILE" ]]; then
            # Key ends with _FILE, value is a file path to read from
            temp_value_file="$value"
            key="${key%_FILE}"  # Remove _FILE suffix from key
        else
            # Write value to temporary file to avoid shell escaping issues
            temp_value_file=$(mktemp)
            printf '%s' "$value" > "$temp_value_file"
            cleanup_temp_file=true
        fi
        
        # Use Python with file input for safe replacement
        python3 -c "
import sys
with open('$output_file', 'r') as f:
    content = f.read()
with open('$temp_value_file', 'r') as f:
    replacement_value = f.read()
content = content.replace('{{$key}}', replacement_value)
with open('$output_file', 'w') as f:
    f.write(content)
"
        # Clean up temp file (only if we created it)
        if [[ "$cleanup_temp_file" == "true" ]]; then
            rm -f "$temp_value_file"
        fi
        shift
    done
}

log "Regenerating HTML files based on existing RPMs..."

# Check if templates directory exists
if [ ! -d "$TEMPLATES_DIR" ]; then
    error "Templates directory not found: $TEMPLATES_DIR"
    exit 1
fi

# Count existing RPMs
total_rpms=$(find . -maxdepth 2 -name "*.rpm" | wc -l)
if [ $total_rpms -eq 0 ]; then
    error "No RPM files found in current directory"
    exit 1
fi

log "Processing $total_rpms existing RPM files"

# Analyze all existing RPMs to get versions
log "Analyzing existing RPM versions..."
mapfile -t _VERSIONS < <(
  find . -maxdepth 2 -name '*.rpm' -exec sh -c '
    rpm -qp --qf "%{VERSION}\n" "$1"
  ' _ {} \;
)

# Sort versions and get latest
if command -v rpmdev-sort &>/dev/null && printf '%s\n' "${_VERSIONS[@]}" | rpmdev-sort >/dev/null 2>&1; then
  LATEST_VERSION=$(printf '%s\n' "${_VERSIONS[@]}" | rpmdev-sort | tail -1)
  versions=$(printf '%s\n' "${_VERSIONS[@]}" | rpmdev-sort | uniq | tr '\n' ' ')
else
  LATEST_VERSION=$(printf '%s\n' "${_VERSIONS[@]}" | sort -V | tail -1)
  versions=$(printf '%s\n' "${_VERSIONS[@]}" | sort -V | uniq | tr '\n' ' ')
fi

log "Latest version: $LATEST_VERSION"
log "All versions: $versions"

# Generate version badges
version_badges=""
if [ -n "$versions" ]; then
    for version in $versions; do
        version_badges="$version_badges            <span class=\"version-badge\">$version</span>"$'\n'
    done
fi

# Generate platform cards and update individual platform pages
platform_cards=""

for platform_dir in */; do
    if [ -d "$platform_dir" ]; then
        platform=$(basename "$platform_dir")

        # Skip non-platform directories
        if [[ "$platform" == ".git" ]] || [[ "$platform" == ".github" ]] || [[ "$platform" == "hack" ]] || [[ "$platform" == "templates" ]]; then
            continue
        fi

        platform_rpms=$(find "$platform_dir" -name "*.rpm" | wc -l)
        
        # Skip if no RPMs in this platform
        if [ $platform_rpms -eq 0 ]; then
            continue
        fi
        
        display_name=$(echo "$platform" | sed 's/-/ /g' | sed 's/\b\w/\U&/g')

        # Generate platform card content
        platform_card=$(cat "$TEMPLATES_DIR/platform-card.html.template")
        platform_card=$(echo "$platform_card" | sed "s|{{DISPLAY_NAME}}|$display_name|g")
        platform_card=$(echo "$platform_card" | sed "s|{{PLATFORM_RPMS}}|$platform_rpms|g")
        platform_card=$(echo "$platform_card" | sed "s|{{PLATFORM}}|$platform|g")
        platform_cards="$platform_cards$platform_card"

        # Update individual platform page
        log "Updating platform page for $platform..."
        
        # Generate RPM list
        rpm_list=""
        while IFS= read -r rpm_file; do
            # Extract package info
            package_name=$(echo "$rpm_file" | sed -E 's/^([^-]+-[^-]+)-[0-9]+\.[0-9]+\.[0-9]+.*/\1/')
            if [[ "$package_name" == *"-"*"-"* ]] || [[ "$package_name" == "$rpm_file" ]]; then
                package_name=$(echo "$rpm_file" | sed -E 's/^([^-]+)-[0-9]+\.[0-9]+\.[0-9]+.*/\1/')
            fi

            version=$(rpm -qp --qf "%{VERSION}\n" "$platform_dir/$rpm_file")

            # Generate RPM item from template
            rpm_item=$(cat "$TEMPLATES_DIR/rpm-item.html.template")
            rpm_item=$(echo "$rpm_item" | sed "s|{{PACKAGE_NAME}}|$package_name|g")
            rpm_item=$(echo "$rpm_item" | sed "s|{{VERSION}}|$version|g")
            rpm_item=$(echo "$rpm_item" | sed "s|{{RPM_FILE}}|$rpm_file|g")
            rpm_list="$rpm_list$rpm_item"
        done < <(find "$platform_dir" -name "*.rpm" -exec basename {} \; | sort)

        # Create platform page from template
        # Use temporary files to pass complex content safely
        temp_rpm_list=$(mktemp)
        printf '%s' "$rpm_list" > "$temp_rpm_list"
        
        substitute_template "$TEMPLATES_DIR/platform.html.template" "$platform_dir/index.html" \
            "DISPLAY_NAME=$display_name" \
            "PLATFORM_RPMS=$platform_rpms" \
            "RPM_LIST_FILE=$temp_rpm_list" \
            "TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        
        rm -f "$temp_rpm_list"
    fi
done

# Generate the main repository index from template
log "Updating main repository index..."
substitute_template "$TEMPLATES_DIR/index.html.template" "index.html" \
    "LATEST_VERSION=$LATEST_VERSION" \
    "VERSION_BADGES=$version_badges" \
    "PLATFORM_CARDS=$platform_cards" \
    "TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
    "REPO_OWNER=$REPO_OWNER" \
    "REPO_NAME=$REPO_NAME"

success "HTML files regenerated successfully!"
echo ""
echo "Repository Summary:"
echo "  Total packages: $total_rpms"
echo "  All versions: $versions"
echo "  Latest version: $LATEST_VERSION"
echo "  Platforms updated: $(echo "$platform_cards" | grep -c 'platform-card' || echo 0)"
echo ""