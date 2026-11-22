# Architecture

## Design goals

Homelab Manager keeps control on the Windows machine, uses standard OpenSSH for remote access, and treats the server as an external system with bounded network operations.

## Runtime flow

```text
User
  │
  ├─ Install.ps1 ── checks prerequisites
  ├─ Setup.ps1 ──── writes local config.json
  └─ Homelab-Manager.ps1
       │
       ├─ config validation
       ├─ OpenSSH / Reach discovery
       ├─ network and TCP probes
       ├─ browser dashboard launchers
       └─ explicit SSH actions to Linux server
```

## Components

| Component | Responsibility |
| --- | --- |
| Configuration | Creates, validates, and reads a user-local JSON file under `%LOCALAPPDATA%\HomelabManager` |
| Connection layer | Uses TCP probes and OpenSSH with explicit timeouts and host-key verification |
| Menu layer | Presents actions; destructive server operations require confirmation |
| Service layer | Builds constrained Docker and shell operations for configured services |
| Discovery layer | Detects the local subnet and gathers ICMP, ARP, DNS, and TCP information |
| Reach integration | Finds an existing Reach installation and launches it; does not install or configure Reach |

## Trust boundaries

- **Repository:** public source and only example configuration.
- **Local configuration:** private connection metadata; never committed.
- **Private key:** owned by OpenSSH/Reach and never read into the repository or configuration.
- **Linux server:** receives commands only after a user selects the corresponding menu action.

## Extending safely

Add new functionality as a dedicated function, validate configuration inputs, apply a timeout to network activity, and document any action that can alter remote state. Never add passwords, API tokens, keys, or real addresses to defaults, fixtures, documentation, or tests.
