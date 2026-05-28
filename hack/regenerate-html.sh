#!/usr/bin/env bash

# Regenerate HTML index files for the RPM repository.
#
# For arch directories (those containing repodata/), packages and their hrefs
# are read from primary.xml.gz so that entries migrated to GitHub Releases
# appear with correct absolute URLs. Disk metadata (size, mtime) is used when
# the file is still present; primary.xml metadata is used as a fallback.
#
# For all other directories the existing filesystem scan is unchanged.

set -euo pipefail

REPO_OWNER="${1:-flightctl}"
REPO_NAME="${2:-flightctl}"
INPUT_DIR="$(pwd)"
TEMPLATES_DIR="$INPUT_DIR/templates"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

substitute_template() {
    local template_file="$1"
    local output_file="$2"
    shift 2

    cp "$template_file" "$output_file"

    while [ $# -gt 0 ]; do
        local key_value="$1"
        local key="${key_value%%=*}"
        local value="${key_value#*=}"

        local temp_value_file
        local cleanup_temp_file=false
        if [[ "$key" == *"_FILE" ]]; then
            temp_value_file="$value"
            key="${key%_FILE}"
        else
            temp_value_file=$(mktemp)
            printf '%s' "$value" > "$temp_value_file"
            cleanup_temp_file=true
        fi

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
        if [[ "$cleanup_temp_file" == "true" ]]; then
            rm -f "$temp_value_file"
        fi
        shift
    done
}

log "Regenerating HTML files..."

if [ ! -d "$TEMPLATES_DIR" ]; then
    error "Templates directory not found: $TEMPLATES_DIR"
    exit 1
fi

# Read all unique versions from primary.xml.gz files across all arch dirs.
# This covers both local packages and those migrated to GitHub Releases.
log "Analyzing RPM versions from repository metadata..."
mapfile -t _VERSIONS < <(
    python3 -c "
import gzip, glob, xml.etree.ElementTree as ET
versions = set()
for path in glob.glob('./**/repodata/*-primary.xml.gz', recursive=True):
    try:
        with gzip.open(path, 'rb') as f:
            tree = ET.parse(f)
        ns = {'md': 'http://linux.duke.edu/metadata/common'}
        for pkg in tree.getroot().findall('md:package', ns):
            ver = pkg.find('md:version', ns)
            if ver is not None:
                v = ver.get('ver', '')
                if v:
                    versions.add(v)
    except Exception:
        pass
for v in sorted(versions):
    print(v)
"
)

if command -v rpmdev-sort &>/dev/null && printf '%s\n' "${_VERSIONS[@]}" | rpmdev-sort >/dev/null 2>&1; then
    LATEST_VERSION=$(printf '%s\n' "${_VERSIONS[@]}" | rpmdev-sort | tail -1)
    versions=$(printf '%s\n' "${_VERSIONS[@]}" | rpmdev-sort | uniq | tr '\n' ' ')
else
    LATEST_VERSION=$(printf '%s\n' "${_VERSIONS[@]}" | sort -V | tail -1)
    versions=$(printf '%s\n' "${_VERSIONS[@]}" | sort -V | uniq | tr '\n' ' ')
fi

log "Latest version: $LATEST_VERSION"
log "All versions: $versions"

dirs=$(cd "$INPUT_DIR"; echo "."; find {epel,fedora} -type d)
for dir in $dirs; do
    log "Processing directory: $dir"

    files_in_dir=()
    if [[ "$dir" == "." ]]; then
        files_in_dir=(epel fedora flightctl-epel.repo flightctl-fedora.repo)
    else
        shopt -s nullglob

        temp_files=()
        for f in "$dir"/*; do
            f=("$(basename "$f")")
            if [[ $f == "index.html" ]]; then
                continue
            fi
            temp_files+=("$f")
        done

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

        # For arch directories: replace the filesystem RPM list with entries
        # read from primary.xml.gz. Each entry is pipe-delimited:
        #   basename|href|size_bytes|unix_timestamp
        # The href is the canonical location (absolute URL for GitHub Releases,
        # relative filename for packages still served from git).
        if [[ -d "$dir/repodata" ]]; then
            primary_gz_rel=$(grep -oP 'repodata/[^"]*-primary\.xml\.gz' \
                "$dir/repodata/repomd.xml" 2>/dev/null | head -1)
            if [[ -n "$primary_gz_rel" && -f "$dir/$primary_gz_rel" ]]; then
                mapfile -t rpms < <(python3 -c "
import sys, gzip, xml.etree.ElementTree as ET
with gzip.open('$dir/$primary_gz_rel', 'rb') as f:
    tree = ET.parse(f)
ns = {'md': 'http://linux.duke.edu/metadata/common'}
seen = set()
for pkg in tree.getroot().findall('md:package', ns):
    loc  = pkg.find('md:location', ns)
    size = pkg.find('md:size', ns)
    ts   = pkg.find('md:time', ns)
    if loc is None:
        continue
    href     = loc.get('href', '')
    n = pkg.find('md:name', ns)
    v = pkg.find('md:version', ns)
    a = pkg.find('md:arch', ns)
    if n is None or v is None or a is None:
        raise ValueError(f'Package missing name/version/arch in primary.xml: href={href}')
    basename = f'{n.text}-{v.get(\"ver\")}-{v.get(\"rel\")}.{a.text}.rpm'
    if basename in seen:
        continue
    seen.add(basename)
    size_bytes = size.get('package', '0') if size is not None else '0'
    timestamp  = ts.get('file', '0')      if ts   is not None else '0'
    print(f'{basename}|{href}|{size_bytes}|{timestamp}')
")
                # Sort pipe-delimited entries by basename using rpmdev-sort
                # when available, otherwise fall back to version-aware sort.
                if [[ ${#rpms[@]} -gt 0 ]]; then
                    if command -v rpmdev-sort &>/dev/null; then
                        declare -A _rpm_map
                        for entry in "${rpms[@]}"; do
                            _rpm_map["${entry%%|*}"]="$entry"
                        done
                        mapfile -t rpms < <(
                            printf '%s\n' "${!_rpm_map[@]}" | rpmdev-sort | while IFS= read -r bn; do
                                echo "${_rpm_map[$bn]}"
                            done
                        )
                        unset _rpm_map
                    else
                        IFS=$'\n' rpms=($(printf '%s\n' "${rpms[@]}" | sort -t'|' -k1,1V))
                    fi
                fi
            fi
        else
            if [[ ${#rpms[@]} -gt 0 ]]; then
                if command -v rpmdev-sort &>/dev/null; then
                    IFS=$'\n' rpms=($(printf '%s\n' "${rpms[@]}" | rpmdev-sort))
                else
                    IFS=$'\n' rpms=($(sort -V <<<"${rpms[*]}"))
                fi
            fi
        fi

        if [[ ${#dirs[@]} -gt 0 ]]; then
            IFS=$'\n' dirs=($(sort <<<"${dirs[*]}"))
        fi
        if [[ ${#others[@]} -gt 0 ]]; then
            IFS=$'\n' others=($(sort <<<"${others[*]}"))
        fi

        files_in_dir=("${dirs[@]}" "${others[@]}" "${rpms[@]}")
    fi

    entries=""
    if [[ $dir != "." ]]; then
        entry=$(cat "$TEMPLATES_DIR/dir-entry.html.template")
        entry=$(echo "$entry" | sed "s|{{NAME}}|..|g")
        entry=$(echo "$entry" | sed "s|{{LAST_MODIFIED}}||g")
        entry=$(echo "$entry" | sed "s|{{SIZE}}||g")
        entries="$entries$entry"
    fi

    for f in "${files_in_dir[@]}"; do
        if [[ -d "$dir/$f" ]]; then
            data=$(du -h --time --time-style="long-iso" --max-depth=0 "$dir/$f" \
                | awk '{print $1 ";" $2 ";" $3 ";" $4}')
            IFS=';' read -r size date time name <<< "$data"
            entry=$(cat "$TEMPLATES_DIR/dir-entry.html.template")
            entry=$(echo "$entry" | sed "s|{{NAME}}|$f|g")
            entry=$(echo "$entry" | sed "s|{{LAST_MODIFIED}}|$date $time|g")
            entry=$(echo "$entry" | sed "s|{{SIZE}}|--|g")
            entries="$entries$entry"
        elif [[ "$f" == *"|"* ]]; then
            # Arch dir RPM entry from primary.xml: basename|href|size_bytes|unix_timestamp
            IFS='|' read -r basename href size_bytes timestamp <<< "$f"
            if [[ -f "$dir/$basename" ]]; then
                data=$(du -h --time --time-style="long-iso" --max-depth=0 "$dir/$basename" \
                    | awk '{print $1 ";" $2 ";" $3}')
                IFS=';' read -r size_human date time <<< "$data"
                last_modified="$date $time"
            else
                size_human=$(numfmt --to=iec "$size_bytes" 2>/dev/null || echo "?")
                last_modified=$(date -d "@$timestamp" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "")
            fi
            entry=$(cat "$TEMPLATES_DIR/file-entry.html.template")
            entry=$(echo "$entry" | sed "s|{{HREF}}|$href|g")
            entry=$(echo "$entry" | sed "s|{{NAME}}|$basename|g")
            entry=$(echo "$entry" | sed "s|{{LAST_MODIFIED}}|$last_modified|g")
            entry=$(echo "$entry" | sed "s|{{SIZE}}|$size_human|g")
            entries="$entries$entry"
        elif [[ -f "$dir/$f" ]]; then
            data=$(du -h --time --time-style="long-iso" --max-depth=0 "$dir/$f" \
                | awk '{print $1 ";" $2 ";" $3 ";" $4}')
            IFS=';' read -r size date time name <<< "$data"
            entry=$(cat "$TEMPLATES_DIR/file-entry.html.template")
            entry=$(echo "$entry" | sed "s|{{HREF}}|$f|g")
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
echo "  All versions: $versions"
echo "  Latest version: $LATEST_VERSION"
echo ""
