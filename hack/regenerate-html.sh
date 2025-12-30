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
total_rpms=$(find . -name "*.rpm" | wc -l)

log "Processing $total_rpms existing RPM files"

# Analyze all existing RPMs to get versions
log "Analyzing existing RPM versions..."
mapfile -t _VERSIONS < <(
  find . -name '*.rpm' -exec sh -c '
    rpm -qp --qf "%{VERSION}\n" "$1" 2> /dev/null || echo "unknown"
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

# Generate list of directories in the RPM repo
dirs=$(cd "$INPUT_DIR"; echo ".";find {epel,fedora} -type d)
for dir in $dirs; do
    log "Processing directory: $dir"

    files_in_dir=()
    if [[ "$dir" == "." ]]; then
        # In root directory, only consider specific files
        files_in_dir=(epel fedora flightctl-epel.repo flightctl-fedora.repo)
    else
        shopt -s nullglob
        # Collect all files, excluding index.html
        temp_files=()
        for f in "$dir"/*; do
            f=("$(basename "$f")")
            if [[ $f == "index.html" ]]; then
                continue
            fi
            temp_files+=("$f")
        done

        # Sort and deduplicate files
        # Directories first, then RPM files sorted by name
        dirs=()
        rpms=()
        others=()

        for f in "${temp_files[@]}"; do
            if [[ -d "$dir/$f" ]]; then
                dirs+=("$f")
            elif [[ "$f" == *.rpm ]]; then
                rpms+=("$f")
            else
                others+=("$f")
            fi
        done

        # Sort each category and combine
        if [[ ${#dirs[@]} -gt 0 ]]; then
            IFS=$'\n' dirs=($(sort <<<"${dirs[*]}"))
        fi
        if [[ ${#rpms[@]} -gt 0 ]]; then
            # Sort RPMs with version-aware sorting if available
            if command -v rpmdev-sort &>/dev/null; then
                IFS=$'\n' rpms=($(printf '%s\n' "${rpms[@]}" | rpmdev-sort))
            else
                IFS=$'\n' rpms=($(sort -V <<<"${rpms[*]}"))
            fi
        fi
        if [[ ${#others[@]} -gt 0 ]]; then
            IFS=$'\n' others=($(sort <<<"${others[*]}"))
        fi

        # Combine: directories first, then other files, then RPMs
        files_in_dir=("${dirs[@]}" "${others[@]}" "${rpms[@]}")
    fi

    entries=""
    if [[ $dir != "." ]]; then
        # Add parent directory link
        entry=$(cat "$TEMPLATES_DIR/dir-entry.html.template")
        entry=$(echo "$entry" | sed "s|{{NAME}}|..|g")
        entry=$(echo "$entry" | sed "s|{{LAST_MODIFIED}}||g")
        entry=$(echo "$entry" | sed "s|{{SIZE}}||g")
        entries="$entries$entry"
    fi
    for f in "${files_in_dir[@]}"; do
        if [[ -d "$dir/$f" ]]; then
            data=$(du -h --time --time-style="long-iso" --max-depth=0 "$dir/$f" | awk '{print $1 ";" $2 ";" $3 ";" $4}')
            IFS=';' read -r size date time name <<< "$data"
            entry=$(cat "$TEMPLATES_DIR/dir-entry.html.template")
            entry=$(echo "$entry" | sed "s|{{NAME}}|$f|g")
            entry=$(echo "$entry" | sed "s|{{LAST_MODIFIED}}|$date $time|g")
            entry=$(echo "$entry" | sed "s|{{SIZE}}|--|g")
            entries="$entries$entry"
        fi
        if [[ -f "$dir/$f" ]]; then
            data=$(du -h --time --time-style="long-iso" --max-depth=0 "$dir/$f" | awk '{print $1 ";" $2 ";" $3 ";" $4}')
            IFS=';' read -r size date time name <<< "$data"
            entry=$(cat "$TEMPLATES_DIR/file-entry.html.template")
            entry=$(echo "$entry" | sed "s|{{NAME}}|$f|g")
            entry=$(echo "$entry" | sed "s|{{LAST_MODIFIED}}|$date $time|g")
            entry=$(echo "$entry" | sed "s|{{SIZE}}|$size|g")
            entries="$entries$entry"
        fi
    done
        
    if [[ "$dir" == "." ]]; then
        substitute_template "$TEMPLATES_DIR/index.html.template" "$dir/index.html" \
            "TABLE_ROWS=$entries" \
            "LATEST_VERSION=$LATEST_VERSION" \
            "LATEST_VERSION_LOCK=${LATEST_VERSION%.*}.*" \
            "TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    else
        substitute_template "$TEMPLATES_DIR/sub.index.html.template" "$dir/index.html" \
            "TABLE_ROWS=$entries" \
            "LATEST_VERSION=$LATEST_VERSION" \
            "LATEST_VERSION_LOCK=${LATEST_VERSION%.*}.*" \
            "TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    fi
done

success "HTML files regenerated successfully!"
echo ""
echo "Repository Summary:"
echo "  Total packages: $total_rpms"
echo "  All versions: $versions"
echo "  Latest version: $LATEST_VERSION"
echo ""
