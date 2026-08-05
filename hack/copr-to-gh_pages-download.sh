#!/usr/bin/env bash

# COPR to GitHub Pages RPM Download Script
# Downloads RPMs from COPR builds using copr-cli only

set -euo pipefail

# Configuration
COPR_PROJECT="@redhat-et/flightctl"
OUTPUT_DIR=".output"
DEST_DIR="$OUTPUT_DIR/copr-rpms-temp"

ONBOARDING_PKG="flightctl-onboarding"
ONBOARDING_MIN_VERSION="1.3.0"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Compare versions: returns 0 (true) if $1 >= $2 (ignoring pre-release suffixes)
version_ge() {
    local ver1="${1#v}" ver2="${2#v}"
    local base1 base2
    base1=$(echo "$ver1" | sed 's/[~-].*//')
    base2=$(echo "$ver2" | sed 's/[~-].*//')
    printf '%s\n%s\n' "$base2" "$base1" | sort -V | head -1 | grep -qxF "$base2"
}

# Duplicate noarch RPMs from x86_64 chroot dirs to corresponding aarch64 dirs
duplicate_noarch_to_aarch64() {
    local dest_dir=$1
    local copied=0

    for x86_dir in "$dest_dir"/*-x86_64; do
        [ -d "$x86_dir" ] || continue
        local aarch64_dir="${x86_dir%-x86_64}-aarch64"
        mkdir -p "$aarch64_dir"
        for noarch_rpm in "$x86_dir"/*.noarch.rpm; do
            [ -f "$noarch_rpm" ] || continue
            local rpm_name
            rpm_name=$(basename "$noarch_rpm")
            if [ ! -f "$aarch64_dir/$rpm_name" ]; then
                cp "$noarch_rpm" "$aarch64_dir/$rpm_name"
                log "  Duplicated $rpm_name to $(basename "$aarch64_dir")"
                copied=$((copied + 1))
            fi
        done
    done

    if [ $copied -gt 0 ]; then
        success "Duplicated $copied noarch RPM(s) to aarch64 directories"
    fi
}

# Find COPR build for specific version
# Usage: find_copr_build <version> [package_name]
find_copr_build() {
    local version="$1"
    local package_name="${2:-}"

    # Remove 'v' prefix if present
    version=${version#v}

    log "Searching for COPR build for version: $version${package_name:+ (package: $package_name)}"

    local builds
    builds=$(copr-cli list-builds "$COPR_PROJECT" --output-format json 2>/dev/null)
    [[ -n $builds ]] || {
        error "copr-cli returned no data – network/auth issue?"
        return 1
    }

    # Check recent successful builds (use higher limit to account for multiple packages)
    for build_id in $(echo "$builds" | jq -r '.[] | select(.state == "succeeded") | .id' | head -40); do
        # Get build details via API
        local build_details
        build_details=$(curl -s "https://copr.fedorainfracloud.org/api_3/build/$build_id" 2>/dev/null || echo '{}')

        # Filter by package name if specified
        if [ -n "$package_name" ]; then
            local build_pkg
            build_pkg=$(echo "$build_details" | jq -r '.source_package.name // empty' 2>/dev/null)
            if [ "$build_pkg" != "$package_name" ]; then
                continue
            fi
        fi

        local build_version
        build_version=$(echo "$build_details" | jq -r '.source_package.version // empty' 2>/dev/null)

        if [ -n "$build_version" ] && [ "$build_version" != "null" ]; then
            # Remove build suffix from COPR version (everything after last dash)
            local copr_clean
            copr_clean=$(echo "$build_version" | sed 's/-[^-]*$//')

            log "  Checking build $build_id: version $copr_clean"

            # Direct match
            if [ "$version" = "$copr_clean" ]; then
                echo "$build_id"
                return 0
            fi

            # Handle pre-release versions (convert dashes to tildes)
            local version_tilde
            version_tilde=$(echo "$version" | sed 's/-rc/~rc/g' | sed 's/-alpha/~alpha/g' | sed 's/-beta/~beta/g')
            if [ "$version_tilde" = "$copr_clean" ]; then
                echo "$build_id"
                return 0
            fi
        fi
    done

    return 1
}

# Download chroot using copr-cli
download_chroot() {
    local build_id=$1
    local chroot=$2
    local dest_dir=$3

    log "Downloading $chroot..."

    if copr-cli download-build "$build_id" --dest "$dest_dir" --chroot "$chroot" 2>/dev/null; then
        success "Downloaded $chroot successfully"
        return 0
    else
        error "Failed to download $chroot"
        return 1
    fi
}

# Main execution
main() {
    local version="${1:-}"

    if [ -z "$version" ]; then
        error "Usage: $0 <version>"
        error "Example: $0 0.8.0"
        error "Example: $0 v0.8.0-rc2"
        exit 1
    fi

    log "Starting COPR download for version: $version"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Find the build
    local build_id
    if ! build_id=$(find_copr_build "$version" "flightctl"); then
        error "Failed to find build for version $version"
        exit 1
    fi

    log "Using COPR build ID: $build_id (flightctl)"

    # Get available chroots
    local build_details
    build_details=$(curl -s "https://copr.fedorainfracloud.org/api_3/build/$build_id")
    [[ -n $build_details ]] || {
        error "Failed to fetch build details for build $build_id – network issue?"
        exit 1
    }
    local available_chroots
    available_chroots=$(echo "$build_details" | jq -r '.chroots[]')

    # Filter to only EPEL and Fedora chroots
    local -a filtered_chroots=()
    while IFS= read -r chroot; do
        # Match EPEL 9+ and Fedora 40+ chroots
        if [[ "$chroot" =~ ^epel-(9|[1-9][0-9]+)-.*$ ]] || [[ "$chroot" =~ ^fedora-(4[0-9]|[5-9][0-9]|[1-9][0-9]{2,})-.*$ ]]; then
            filtered_chroots+=("$chroot")
        fi
    done <<< "$available_chroots"

    if [ ${#filtered_chroots[@]} -eq 0 ]; then
        error "No EPEL or Fedora chroots found for build $build_id"
        exit 1
    fi

    log "Found chroots: ${filtered_chroots[*]}"

    # Clean destination directory
    rm -rf "$DEST_DIR"
    mkdir -p "$DEST_DIR"

    # Download flightctl chroots
    local success_count=0
    local total_count=0

    for chroot in "${filtered_chroots[@]}"; do
        total_count=$((total_count + 1))
        if download_chroot "$build_id" "$chroot" "$DEST_DIR"; then
            success_count=$((success_count + 1))
        fi
    done

    # Download flightctl-onboarding if version >= 1.3.0
    if version_ge "$version" "$ONBOARDING_MIN_VERSION"; then
        log "Version $version >= $ONBOARDING_MIN_VERSION, searching for $ONBOARDING_PKG..."

        local onboarding_build_id
        if onboarding_build_id=$(find_copr_build "$version" "$ONBOARDING_PKG"); then
            log "Using COPR build ID: $onboarding_build_id ($ONBOARDING_PKG)"

            local onboarding_details
            onboarding_details=$(curl -s "https://copr.fedorainfracloud.org/api_3/build/$onboarding_build_id")
            local onboarding_chroots
            onboarding_chroots=$(echo "$onboarding_details" | jq -r '.chroots[]')

            local -a onboarding_filtered=()
            while IFS= read -r chroot; do
                if [[ "$chroot" =~ ^epel-(9|[1-9][0-9]+)-.*$ ]] || [[ "$chroot" =~ ^fedora-(4[0-9]|[5-9][0-9]|[1-9][0-9]{2,})-.*$ ]]; then
                    onboarding_filtered+=("$chroot")
                fi
            done <<< "$onboarding_chroots"

            for chroot in "${onboarding_filtered[@]}"; do
                total_count=$((total_count + 1))
                if download_chroot "$onboarding_build_id" "$chroot" "$DEST_DIR"; then
                    success_count=$((success_count + 1))
                fi
            done

            duplicate_noarch_to_aarch64 "$DEST_DIR"
        else
            error "WARNING: $ONBOARDING_PKG build not found for version $version"
            error "The package may not be published yet for this version."
        fi
    else
        log "Version $version < $ONBOARDING_MIN_VERSION, skipping $ONBOARDING_PKG"
    fi

    # Clean up unwanted RPMs
    log "Cleaning up packages..."
    find "$DEST_DIR" -name "*debuginfo*.rpm" -delete 2>/dev/null || true
    find "$DEST_DIR" -name "*debugsource*.rpm" -delete 2>/dev/null || true
    find "$DEST_DIR" -name "*.src.rpm" -delete 2>/dev/null || true

    # Create repository metadata
    log "Creating repository metadata..."
    for chroot_dir in "$DEST_DIR"/*; do
        if [ -d "$chroot_dir" ]; then
            local chroot
            chroot=$(basename "$chroot_dir")
            createrepo_c "$chroot_dir" || {
                error "Failed to create repo metadata for $chroot"
                continue
            }
        fi
    done

    # Summary
    local total_rpms
    total_rpms=$(find "$DEST_DIR" -name "*.rpm" 2>/dev/null | wc -l)

    success "Download completed!"
    echo "  Successful chroots: $success_count/$total_count"
    echo "  Total RPMs: $total_rpms"
    echo "  Output directory: $DEST_DIR"
    echo ""
    echo "Next: Run create-rpm-repo.sh to generate the repository structure"
}

main "$@"
