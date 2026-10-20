# VBridge WDTT source

Ordinary **WDTT** deployments use the imported WDTT server in this directory.

- Commit: `83570c594978c17dcc44eee5279d57f2e9a32e89`
- Imported from the user-provided `.dev/wdtt-server-main.zip` archive.
- License: GPLv3; see `LICENSE`.

`script/build_wdtt_server_assets.sh` builds `wdtt-linux-amd64` and
`wdtt-linux-arm64` from these sources. VBridge uploads the matching binary and
uses `TurnBridge/DeployAssets/wdtt.sh` for installation, rather than running the
upstream interactive `install.sh`.

The server uses `/etc/wdtt/passwords.json`, `/etc/wdtt/wg-keys.dat`, the `wdtt`
systemd service and the `wdtt0` interface. Client management uses VBridge's SSH
database adapter; mutations briefly stop and restart the service to apply changes
and prevent its in-memory database from overwriting edits. Both `device_id` and
`device_ids`, and names stored as `label` or `marker`, are supported.

WDTT Plus continues to build separately from `../wdtt-server`. Its extended
runtime limits, admin socket, and `-existing-tun` option are not available in the ordinary WDTT server.
SRTP and CSQTT are unaffected.
