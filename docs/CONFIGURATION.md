# Configuration

Run `Setup.ps1` to create local configuration. The resulting file is stored at:

```text
%LOCALAPPDATA%\HomelabManager\config.json
```

It is excluded from Git.

## Core settings

| Setting | Purpose | Example |
| --- | --- | --- |
| `server.ip` | IPv4 address of the Linux server | `192.168.1.50` |
| `server.sshPort` | SSH listener port | `22` |
| `server.sshUser` | SSH account name | `homelab` |
| `server.mac` | MAC address for Wake-on-LAN | `02:00:00:00:00:01` |
| `ssh.keyPath` | Local private-key path | `%USERPROFILE%\.ssh\id_ed25519` |
| `wakeOnLan.broadcastAddress` | LAN broadcast address | `192.168.1.255` |

## Key-based SSH

Create or use a private key locally, authorize its public key on the server, and place only the **path** to the private key in configuration. Do not put the private-key content in JSON, source files, issues, or screenshots.

## Dashboard and service settings

The default configuration also contains dashboard port definitions and remote service command paths. Review every value before using service management features. The app validates common malformed values, but validation does not replace reviewing remote commands for your environment.
