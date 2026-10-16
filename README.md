# Hydra RPM Updater

A simple RPM updater for Hydra Launcher on Fedora and other `dnf`-based Linux distributions.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/krissuu7/hydra-rpm-updater-installer/main/install-hydra-updater.sh | sudo bash
```

## Features

- Checks GitHub Releases for new Hydra Launcher versions.
- Downloads and installs RPM updates using `dnf`.
- Runs automatically via a systemd timer, approximately every 6 hours.
- Updates its own script from this repository after validating its syntax.
- Removes temporary RPM files after installation attempts.
- Sends desktop notifications after successful installations or updates.
- Logs activity to the systemd journal.

## Commands

Check for updates manually:

```bash
sudo systemctl start hydra-rpm-updater.service
```

Check timer status:

```bash
systemctl status hydra-rpm-updater.timer
```

View logs:

```bash
sudo journalctl -u hydra-rpm-updater.service -n 50 --no-pager
```

Disable automatic checks:

```bash
sudo systemctl disable --now hydra-rpm-updater.timer
```

Re-enable automatic checks:

```bash
sudo systemctl enable --now hydra-rpm-updater.timer
```

## Requirements

- Fedora or another `dnf`-based distribution
- x86_64 system
- `curl`, `jq`, `rpm`, `dnf`, and systemd

The installer installs the required packages if needed.
