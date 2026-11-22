# Contributing

Thanks for improving Homelab Manager.

## Before submitting

1. Do not include real IP addresses, MAC addresses, usernames, private paths, credentials, logs, keys, or compiled binaries.
2. Run the local checks:

   ```powershell
   .\tests\Run-Tests.ps1
   ```

3. Keep new network operations bounded by a timeout.
4. Preserve explicit confirmations for actions that change remote server state.
5. Update documentation when adding a menu item, configuration field, or remote command.

## Pull requests

Describe the user problem, the behavior change, and the verification performed. Keep pull requests focused and avoid unrelated formatting churn.
