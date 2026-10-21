# VBridge WDTT Simple source

**WDTT Simple** deployments use the imported WDTT server in this directory.

- Commit: `83570c594978c17dcc44eee5279d57f2e9a32e89`
- Imported from the user-provided `.dev/wdtt-server-main.zip` archive.
- License: GPLv3; see `LICENSE`.

`script/build_wdtt_server_assets.sh` builds `wdtt-simple-linux-amd64` and
`wdtt-simple-linux-arm64` from these sources. VBridge uploads the matching binary and
uses `TurnBridge/DeployAssets/wdtt-simple.sh` for installation, rather than running the
upstream interactive `install.sh`.

The server uses `/etc/wdtt/passwords.json`, `/etc/wdtt/wg-keys.dat`, the `wdtt`
systemd service and the `wdtt0` interface. Client management uses VBridge's SSH
database adapter; mutations briefly stop and restart the service to apply changes
and prevent its in-memory database from overwriting edits. Both `device_id` and
`device_ids`, and names stored as `label` or `marker`, are supported.

VBridge adds native Server Backups to this imported server: manual snapshots,
verification, export, deletion, retention, and automatic backups run through a
root-only `/run/wdtt/simple-backup.sock` endpoint. Snapshot creation captures a
copy of the in-memory database without stopping the VPN. The policy and catalog
live under `/var/lib/wdtt-server-installer/backups/simple`, separately from the
WDTT/Plus catalog. Multi-device bindings and server keys are retained. The backup
engine and file validation are adapted from `../wdtt-server/server_backup.go`
and `database_persistence.go`. The adapted server reports version `simple-1`.

Exported snapshots can be selected in Deploy's Restore Server, which also accepts
the older `wdtt-plus-state` archive. VBridge checks file hashes, adapts the client
database to the installed variant, backs up existing files, and restores them
if the new state fails to start. Restoring Simple's multi-device accesses to
WDTT/Plus requires unbinding extra devices first. Current deployment credentials
are kept so they remain consistent with the installed systemd unit.

WDTT and WDTT Plus build separately from `../wdtt-server`. Their extended
runtime limits, full admin socket, and `-existing-tun` option are not available in WDTT Simple.
SRTP and CSQTT are unaffected.
