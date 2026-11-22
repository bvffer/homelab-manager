# Homelab Manager

> A Windows-first control center for a Linux homelab—built around explicit actions, local configuration, and key-based SSH.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Windows-0078D4?logo=windows&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

Homelab Manager is a console application for operating a single Linux server from Windows. It combines connection diagnostics, Wake-on-LAN, dashboard checks, Docker/service actions, LAN discovery, and an optional Reach SSH-client launcher in one menu-driven tool.

## Why it exists

Most homelab tasks are small but repetitive: checking whether SSH is available, opening the right dashboard, waking a sleeping server, or confirming that a service is really listening. This project provides a visible, guided path for those actions without storing passwords or private keys.

## Capabilities

| Area | What it provides |
| --- | --- |
| Connectivity | TCP checks, SSH authentication diagnostics, host-key-safe commands |
| Network | Wake-on-LAN, LAN discovery, local subnet detection, server interface checks |
| Operations | Service status, Docker controls, logs, image actions, controlled power operations |
| Dashboards | Health checks and browser launchers for configured web services |
| Remote access | OpenSSH support and optional Reach launcher with a paste-ready `user@host:port` value |
| Safety | Explicit menu confirmations, bounded timeouts, local-only configuration, no saved passwords |

## Quick start

1. Clone or download this repository.
2. Open PowerShell in the project folder.
3. Check prerequisites:

   ```powershell
   .\Install.ps1
   ```

4. Run first-run setup. It asks for connection metadata only—never passwords or private-key contents:

   ```powershell
   .\Setup.ps1
   ```

5. Launch the manager:

   ```powershell
   .\Homelab-Manager.ps1
   ```

See [Configuration](docs/CONFIGURATION.md) for every setting and [Architecture](docs/ARCHITECTURE.md) for the project structure.

## Build an EXE

PS2EXE is optional. Install it only when you want a compiled executable:

```powershell
.\Install.ps1 -InstallPs2Exe
.\Build.ps1
```

The executable is written to `dist/`, which is intentionally excluded from Git.

## Reach SSH client

Install Reach yourself if you want to use it. In **Network**, choose **Launch Reach (SSH Client)**. Homelab Manager opens Reach and shows a paste-ready value:

```text
username@host:port
```

Select your own private-key file in Reach. Never commit, paste, or share a private key.

## Repository map

```text
Homelab-Manager.ps1  Main application
Install.ps1          Prerequisite checker and optional PS2EXE installation
Setup.ps1            Interactive local configuration wizard
Build.ps1            EXE build entry point
config.example.json  Safe example configuration
docs/                Architecture and configuration documentation
tests/               Source and privacy regression checks
.github/             CI and contribution templates
```

## Security model

- The app uses the user's local OpenSSH private key and never stores passwords or key material.
- SSH host-key verification is not disabled.
- Server-changing actions require an explicit menu choice and, where appropriate, a typed confirmation.
- `.gitignore` blocks local configuration, keys, logs, backups, and binaries.
- CI scans the source for known personal-value patterns before accepting changes.

Please read [SECURITY.md](SECURITY.md) before reporting security issues and [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
