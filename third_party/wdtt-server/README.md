# WDTT Server

This directory contains the Linux WDTT and WDTT Plus server sources imported from:

- Repository: https://github.com/Ivan4537/WDTT-Plus
- Branch: `main`
- Commit: `68bc4af91597102aef5194a2cbd40c916b4fb175`
- License: GNU GPL v3.0

VBridge builds these sources in GitHub Actions into deploy assets:

- `TurnBridge/DeployAssets/wdtt-linux-amd64`
- `TurnBridge/DeployAssets/wdtt-linux-arm64`
- `TurnBridge/DeployAssets/wdtt-plus-linux-amd64`
- `TurnBridge/DeployAssets/wdtt-plus-linux-arm64`

WDTT restores the server and installer combination used before commit `92c0070`. WDTT Plus uses the same sources with its extended installer and runtime controls. WDTT Simple assets are built separately from `../wdtt-stable`.

The generated binaries are intentionally not committed.
