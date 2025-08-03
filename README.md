# FlightCtl RPM Repository

This repository contains production-ready RPM packages for FlightCtl.

## Installation

### EPEL (RHEL 9, CentOS Stream 9, Rocky Linux 9)

```bash
sudo dnf config-manager addrepo --from-repofile=https://flightctl.github.io/flightctl-rpm/flightctl-epel.repo
sudo dnf install flightctl-agent flightctl-cli
```

### Fedora

```bash
sudo dnf config-manager addrepo --from-repofile=https://flightctl.github.io/flightctl-rpm/flightctl-fedora.repo
sudo dnf install flightctl-agent flightctl-cli
```

### Install Specific Version

```bash
sudo dnf install flightctl-agent-0.8.1 flightctl-cli-0.8.1
```

## Updates

This repository can be updated manually using GitHub Actions workflow.

### Manual Update

To update the repository with a new FlightCtl version:

```bash
gh workflow run update-rpm-repo.yml --repo flightctl/flightctl-rpm -f version=0.8.1
```

Replace `0.8.1` with the desired version number.

### Requirements

- The specified version must already be available in the COPR repository
- The workflow will download RPMs and update the repository structure
- A branch will be created and pushed - you'll need to manually create the PR

### After Running the Workflow

The workflow will:
1. Create a new branch with the updated content
2. Push the branch to the repository
3. Provide instructions for creating the PR manually

You can then create the PR using the GitHub CLI command provided in the workflow output, or by visiting the GitHub compare URL.

