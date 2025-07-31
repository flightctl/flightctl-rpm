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

## Available Packages

- **flightctl-agent**: FlightCtl agent for edge devices
- **flightctl-cli**: FlightCtl command-line interface

## Available Versions

0.5.1 0.7.1 0.7.2 0.8.1 

## Repository Structure

This repository is automatically generated from COPR builds. Each platform directory contains:

- RPM packages for that platform
- Repository metadata (`repodata/`)
- Platform-specific index page

## Updates

This repository is automatically updated when new FlightCtl releases are published. PRs are created automatically and auto-merged after successful builds.

## Source

Generated from: https://github.com/flightctl/flightctl
