# HP Homelab Manager

A Windows PowerShell console control center for a Linux homelab. It offers SSH diagnostics, Wake-on-LAN, dashboard checks, Docker and service controls, LAN discovery, and an optional Reach SSH-client launcher.

## Safe by default

This repository contains **no real server addresses, usernames, MAC addresses, credentials, private keys, logs, or compiled binaries**. Your local settings are created only when you run setup and are excluded by `.gitignore`.

## Quick start

1. Open PowerShell in this folder.
2. Check prerequisites:

   ```powershell
   .\Install.ps1
   ```

3. Run the first-run wizard. It asks only for connection metadata—not passwords or private-key contents:

   ```powershell
   .\Setup.ps1
   ```

4. Start the app:

   ```powershell
   .\HP-Homelab-Manager.ps1
   ```

## Build an EXE

Install PS2EXE only if you want a compiled executable, then build:

```powershell
.\Install.ps1 -InstallPs2Exe
.\Build.ps1
```

The executable is written to `dist/`, which is not committed.

## Reach SSH client

Install Reach yourself if desired. In the Network menu, select **Launch Reach (SSH Client)**. The app displays a paste-ready value in this format:

```text
username@host:port
```

Choose your own private-key file in Reach. Never commit, paste, or share its contents.

## Security notes

- The app uses your local OpenSSH private key; it never stores passwords or key material.
- SSH host-key verification is not disabled.
- Review commands before running administrative server actions.
- Keep `config.json`, private keys, logs, and EXEs out of source control.
