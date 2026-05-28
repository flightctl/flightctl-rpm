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

This repository uses a split storage model to avoid committing large RPM
binaries to git while still providing a fully functional DNF repository.

### How it works

1. **GitHub Pages** (https://rpm.flightctl.io) serves DNF repository metadata
   (`repodata/`) and HTML index pages. This is the `baseurl` in the `.repo` files.
2. **GitHub Releases** store the actual RPM packages as release assets. Each
   release tag (e.g. `v1.2.0`) contains all RPMs for that version across all
   platforms and architectures.
3. When DNF resolves a package, it reads `repodata/primary.xml.gz` from GitHub
   Pages. Each package's `<location href>` points directly to its GitHub Release
   download URL, so DNF fetches the full RPM from there — GitHub Pages never
   serves the RPM binary itself.

### Stub RPMs

An RPM file consists of a lead, signature header, main header, and a compressed
cpio payload. Tools like `createrepo_c` only read the headers to generate
repository metadata — the payload is never inspected.

**Stub RPMs** are RPMs with the payload stripped off, leaving only the lead and
headers (~15KB instead of 7–22MB). They are stored in `rpm-stubs/` and serve
two purposes:

- **Metadata generation**: `createrepo_c` runs against the stubs to produce
  correct `primary.xml`, `filelists.xml`, and `other.xml`. Three fields that
  `createrepo_c` computes from the file on disk (checksum, size, location href)
  are then corrected using values from `rpm-manifest.json`.
- **Reproducibility**: since every package version has a stub committed to git,
  `regenerate-rpm-repo.py` can always rebuild the complete repodata from scratch.
  There is no incremental state to get out of sync.

Each `rpm-stubs/{arch}/rpm-manifest.json` maps the stub filename to the real
RPM's sha256, size, and GitHub Release download URL. This is the source of truth
for the post-processing step.

Stubs are excluded from GitHub Pages via `.jekyllignore` — they exist only for
metadata generation and are never served to end users.

### Why this approach

- **Git repo size**: committing full RPMs grew the repository to ~11GB. Stubs
  reduce new-version commits to ~100KB instead of ~50–100MB of binaries.
- **No retention policy**: GitHub Releases have no expiration, unlike some
  artifact storage. Packages remain available indefinitely.
- **Full rebuild from scratch**: because stubs for every version are committed,
  repodata can be regenerated at any time without needing the original RPMs.
- **Standard DNF workflow**: end users install packages with `dnf install` as
  usual — the redirect to GitHub Releases is transparent.

## Updates

New releases are added via the GitHub Actions workflow, triggered manually
via `workflow_dispatch`.

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

