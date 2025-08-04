#!/usr/bin/env bash

# Create RPM Repository Structure Script
# Converts COPR downloads into a flightctl-rpm repository structure

set -euo pipefail

# Configuration
OUTPUT_DIR=".output"
COPR_DOWNLOAD_DIR="${1:-$OUTPUT_DIR/copr-rpms-temp}"
REPO_OUTPUT_DIR="${2:-$OUTPUT_DIR/flightctl-rpm}"
REPO_OWNER="${3:-flightctl}"
REPO_NAME="${4:-flightctl}"
INPUT_DIR="$(pwd)"  # Current directory where script is run from (flightctl-rpm)
TEMPLATES_DIR="$INPUT_DIR/templates"  # Templates are in the current directory

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
        local key="${key_value%=*}"
        local value="${key_value#*=}"
        
        # Write value to temporary file to avoid shell escaping issues
        local temp_value_file=$(mktemp)
        printf '%s' "$value" > "$temp_value_file"
        
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
        # Clean up temp file
        rm -f "$temp_value_file"
        shift
    done
}

# Show usage
if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    echo "Usage: $0 [copr_download_dir] [repo_output_dir] <repo_owner> <repo_name>"
    echo "Example: $0 flightctl flightctl"
    echo "Example: $0 .output/copr-rpms-temp .output/flightctl-rpm flightctl flightctl"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Validate inputs
if [ ! -d "$COPR_DOWNLOAD_DIR" ]; then
    error "COPR download directory not found: $COPR_DOWNLOAD_DIR"
    exit 1
fi

rpm_count=$(find "$COPR_DOWNLOAD_DIR" -name "*.rpm" | wc -l)
if [ $rpm_count -eq 0 ]; then
    error "No RPM files found in $COPR_DOWNLOAD_DIR"
    exit 1
fi

log "Processing $rpm_count RPM files from $COPR_DOWNLOAD_DIR"

# Auto-detect the latest version
mapfile -t _VERSIONS < <(
  find "$COPR_DOWNLOAD_DIR" -name '*.rpm' -exec sh -c '
    rpm -qp --qf "%{VERSION}\n" "$1"
  ' _ {} \;
)
if command -v rpmdev-sort &>/dev/null; then
  LATEST_VERSION=$(printf '%s\n' "${_VERSIONS[@]}" | rpmdev-sort | tail -1)
else
  LATEST_VERSION=$(printf '%s\n' "${_VERSIONS[@]}" | sort -V | tail -1)
fi

log "Detected latest version: $LATEST_VERSION"

# Create repository structure (one-level, RPMs only)
log "Creating RPM repository structure..."
rm -rf "$REPO_OUTPUT_DIR"
mkdir -p "$REPO_OUTPUT_DIR"

# Copy RPM files directly to repository root structure
log "Copying RPM files..."
for platform_dir in "$COPR_DOWNLOAD_DIR"/*/; do
    if [ -d "$platform_dir" ]; then
        platform=$(basename "$platform_dir")
        target_dir="$REPO_OUTPUT_DIR/$platform"

        mkdir -p "$target_dir"
        find "$platform_dir" -name "*.rpm" -exec cp {} "$target_dir/" \;

        if [ -d "$platform_dir/repodata" ]; then
            cp -r "$platform_dir/repodata" "$target_dir/"
        fi

        rpm_count=$(find "$target_dir" -name "*.rpm" | wc -l)
        log "  $platform: copied $rpm_count RPM files"
    fi
done

# Create repository configuration files
log "Creating repository configuration files..."

cat > "$REPO_OUTPUT_DIR/flightctl-epel.repo" << EOF
[flightctl]
name=FlightCtl RPM Repository (EPEL)
type=rpm-md
baseurl=https://flightctl.github.io/flightctl-rpm/epel-9-\$basearch/
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/@redhat-et/flightctl/pubkey.gpg
enabled=1
enabled_metadata=1
metadata_expire=1d
EOF

cat > "$REPO_OUTPUT_DIR/flightctl-fedora.repo" << EOF
[flightctl]
name=FlightCtl RPM Repository (Fedora)
type=rpm-md
baseurl=https://flightctl.github.io/flightctl-rpm/fedora-\$releasever-\$basearch/
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/@redhat-et/flightctl/pubkey.gpg
enabled=1
enabled_metadata=1
metadata_expire=1d
EOF

# Analyze repository content
total_rpms=$(find "$REPO_OUTPUT_DIR" -name "*.rpm" | wc -l)
mapfile -t _REPO_VERSIONS < <(
  find "$REPO_OUTPUT_DIR" -name '*.rpm' -exec sh -c '
    rpm -qp --qf "%{VERSION}\n" "$1"
  ' _ {} \;
)
if command -v rpmdev-sort &>/dev/null; then
  versions=$(printf '%s\n' "${_REPO_VERSIONS[@]}" | rpmdev-sort | uniq | tr '\n' ' ')
else
  versions=$(printf '%s\n' "${_REPO_VERSIONS[@]}" | sort -V | uniq | tr '\n' ' ')
fi

# Create main repository index
log "Creating main repository index..."

# Generate version badges
version_badges=""
if [ -n "$versions" ]; then
    for version in $versions; do
        version_badges="$version_badges            <span class=\"version-badge\">$version</span>"
    done
fi

# Generate platform cards (will be filled later)
platform_cards=""

# Create platform cards and individual platform pages
for platform_dir in "$REPO_OUTPUT_DIR"/*/; do
    if [ -d "$platform_dir" ]; then
        platform=$(basename "$platform_dir")

        # Skip if it's not a platform directory (and skip templates directory)
        if [[ "$platform" == "repodata" ]] || [[ "$platform" == "templates" ]]; then
            continue
        fi

        platform_rpms=$(find "$platform_dir" -name "*.rpm" | wc -l)
        display_name=$(echo "$platform" | sed 's/-/ /g' | sed 's/\b\w/\U&/g')

        # Generate platform card content
        platform_card=$(cat "$TEMPLATES_DIR/platform-card.html.template")
        platform_card=$(echo "$platform_card" | sed "s|{{DISPLAY_NAME}}|$display_name|g")
        platform_card=$(echo "$platform_card" | sed "s|{{PLATFORM_RPMS}}|$platform_rpms|g")
        platform_card=$(echo "$platform_card" | sed "s|{{PLATFORM}}|$platform|g")
        platform_cards="$platform_cards$platform_card"

        # Create individual platform page
        log "Creating platform page for $platform..."
        
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
        substitute_template "$TEMPLATES_DIR/platform.html.template" "$platform_dir/index.html" \
            "DISPLAY_NAME=$display_name" \
            "PLATFORM_RPMS=$platform_rpms" \
            "RPM_LIST=$rpm_list" \
            "TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    fi
done

# Generate the main repository index from template
substitute_template "$TEMPLATES_DIR/index.html.template" "$REPO_OUTPUT_DIR/index.html" \
    "LATEST_VERSION=$LATEST_VERSION" \
    "VERSION_BADGES=$version_badges" \
    "PLATFORM_CARDS=$platform_cards" \
    "TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
    "REPO_OWNER=$REPO_OWNER" \
    "REPO_NAME=$REPO_NAME"

# README.md is managed manually in the repository root
log "Skipping README.md generation (managed manually)"

# Copy CSS files from current directory
log "Copying CSS files..."
if [ -f "$INPUT_DIR/styles.css" ]; then
    cp "$INPUT_DIR/styles.css" "$REPO_OUTPUT_DIR/"
    log "Copied styles.css"
else
    log "Warning: styles.css not found in $INPUT_DIR"
fi

if [ -f "$INPUT_DIR/platform-styles.css" ]; then
    cp "$INPUT_DIR/platform-styles.css" "$REPO_OUTPUT_DIR/"
    log "Copied platform-styles.css"
else
    log "Warning: platform-styles.css not found in $INPUT_DIR"
fi

# Summary
success "RPM repository structure created successfully!"
echo ""
echo "Repository Summary:"
echo "  URL: https://flightctl.github.io/flightctl-rpm/"
echo "  Total packages: $total_rpms"
echo "  Output directory: $REPO_OUTPUT_DIR"
echo "  Latest version: $LATEST_VERSION"
echo ""
echo "Structure created:"
echo "  - index.html (main repository page from template)"
echo "  - styles.css, platform-styles.css (external stylesheets)"
echo "  - flightctl-epel.repo, flightctl-fedora.repo (repository configs)"
echo "  - Platform directories with RPMs and metadata (from templates)"
echo "  - Templates used: $TEMPLATES_DIR"
echo ""
echo "Ready for PR to flightctl/flightctl-rpm repository!"
