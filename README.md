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

1. **Start the workflow:**
   ```bash
   gh workflow run update-rpm-repo.yml --repo flightctl/flightctl-rpm -f version=0.8.1
   ```
   Replace `0.8.1` with the desired version number.

2. **Check workflow status:**
   ```bash
   gh run list --repo flightctl/flightctl-rpm --limit 1
   ```
   Wait for the status to show a green checkmark (✓) and `completed success`. The workflow typically takes 1-2 minutes to complete.

3. **After successful completion:**
   - The workflow creates a new branch named `update-rpm-VERSION-TIMESTAMP`
   - All RPM files, HTML pages, and repository metadata are updated
   - The workflow output provides a GitHub CLI command to create the PR

   **To get the full workflow output:**
   ```bash
   # View the workflow run details and get the job ID
   gh run view --repo flightctl/flightctl-rpm
   
   # Get the complete workflow log (replace JOB_ID with the job ID from above)
   gh run view --log --job=JOB_ID --repo flightctl/flightctl-rpm
   ```
   
   Example:
   ```bash
   gh run view 16719137160 --repo flightctl/flightctl-rpm  # Shows job ID 47319307112
   gh run view --log --job=47319307112 --repo flightctl/flightctl-rpm
   ```
   
   The log contains the complete `gh pr create` command ready to copy and execute.

4. **Create the Pull Request:**
   Use the command provided in the workflow output, which will look like:
   ```bash
   gh pr create \
     --repo flightctl/flightctl-rpm \
     --title 'Update RPM repository for FlightCtl 0.8.1' \
     --head 'update-rpm-0.8.1-20240804-123456' \
     --base main \
     --body 'Updates RPM repository with FlightCtl version 0.8.1'
   ```
   
   Or visit the GitHub compare URL provided in the workflow output.

5. **Review and merge:**
   - Review the PR to ensure all platforms and packages are updated correctly
   - Merge the PR to make the new version available at https://flightctl.github.io/flightctl-rpm/

### Requirements

- The specified version must already be available in the COPR repository
- You need `gh` CLI tool installed and authenticated
- The workflow requires manual PR creation for safety

