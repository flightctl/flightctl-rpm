# Flight Control RPM Repository

RPM repository for the Flight Control project. Repository metadata is served
via GitHub Pages at https://rpm.flightctl.io, while RPM packages are stored as
GitHub Release assets and downloaded directly by DNF.

## Installation

### EPEL 9 (RHEL 9, CentOS Stream 9, Rocky Linux 9)

```bash
sudo dnf config-manager --add-repo https://rpm.flightctl.io/flightctl-epel9.repo
sudo dnf install flightctl-agent flightctl-cli
```

### EPEL 10 (RHEL 10, CentOS Stream 10, Rocky Linux 10)

```bash
sudo dnf config-manager addrepo --from-repofile=https://rpm.flightctl.io/flightctl-epel10.repo
sudo dnf install flightctl-agent flightctl-cli
```

### Fedora

```bash
sudo dnf config-manager addrepo --from-repofile=https://rpm.flightctl.io/flightctl-fedora.repo
sudo dnf install flightctl-agent flightctl-cli
```

### Install Specific Version

```bash
sudo dnf install flightctl-agent-1.1.2 flightctl-cli-1.1.2
```

## Architecture

This repository uses a split storage model:

- **GitHub Pages** serves DNF repository metadata (`repodata/`) and HTML index pages
- **GitHub Releases** store the actual RPM packages as release assets
- **`rpm-stubs/`** contains payload-stripped stub RPMs (~15KB each) used by `createrepo_c` to generate metadata; these are excluded from GitHub Pages via `.jekyllignore`
- **`rpm-stubs/*/rpm-manifest.json`** maps each stub to the real RPM's sha256, size, and GitHub Release download URL

When DNF resolves a package, it reads the metadata from GitHub Pages, then downloads the full RPM directly from the GitHub Release URL in the `<location href>`.

## Updates

New releases are added via the GitHub Actions workflow, triggered automatically
on release publication or manually via `workflow_dispatch`.

### Manual Update

1. **Start the workflow:**
   ```bash
   gh workflow run update-rpm-repo.yml --repo flightctl/flightctl-rpm -f version=1.2.0
   ```

2. **Check workflow status:**
   ```bash
   gh run list --repo flightctl/flightctl-rpm --limit 1
   ```

3. **After successful completion:**
   - RPMs are downloaded from COPR and uploaded to a GitHub Release
   - Payload-stripped stubs and manifest are created in `rpm-stubs/`
   - Repository metadata is regenerated from all stubs
   - HTML index pages are rebuilt
   - A branch is created with the changes

4. **Create and merge the Pull Request** from the workflow output to publish.

### Requirements

- The specified version must already be available in the COPR repository
- You need `gh` CLI tool installed and authenticated
- The workflow requires manual PR creation for safety

## Repository Scripts

- `hack/add-release-stubs.py` — creates stubs and updates manifests for a new release
- `hack/regenerate-rpm-repo.py` — regenerates all repodata from stubs via `createrepo_c`
- `hack/regenerate-html.sh` — rebuilds HTML index pages from repodata

