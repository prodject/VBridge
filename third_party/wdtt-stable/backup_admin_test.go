package main

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSimpleBackupAdminSocket(t *testing.T) {
	configDir, database := backupTestConfig(t)
	previous := db
	db = database
	t.Cleanup(func() { db = previous })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	path := filepath.Join(t.TempDir(), "run", "backup.sock")
	if err := startSimpleBackupAdmin(ctx, configDir, path); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("socket permissions: %v, %v", info, err)
	}
	call := func(password string, args ...string) adminResponse {
		t.Helper()
		conn, err := net.Dial("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
		if err := json.NewEncoder(conn).Encode(simpleBackupRequest{MainPassword: password, Args: args}); err != nil {
			t.Fatal(err)
		}
		var response adminResponse
		if err := json.NewDecoder(conn).Decode(&response); err != nil {
			t.Fatal(err)
		}
		return response
	}
	if call("wrong", "backup-create").OK || call(database.MainPassword, "delete").OK {
		t.Fatal("socket accepted an unauthorized or non-backup command")
	}
	configured := call(database.MainPassword, "backup-configure", "--enabled", "true", "--interval-hours", "6", "--retention", "2")
	if !configured.OK || configured.BackupStatus == nil || configured.BackupStatus.ValidCount != 1 || !configured.BackupStatus.Policy.Enabled {
		t.Fatalf("configure: %+v", configured)
	}
	created := call(database.MainPassword, "backup-create")
	if !created.OK || created.Backup == nil || !created.Backup.Valid {
		t.Fatalf("create: %+v", created)
	}
	id := created.Backup.ID
	if verified := call(database.MainPassword, "backup-verify", "--id", id); !verified.OK {
		t.Fatalf("verify: %+v", verified)
	}
	exported := call(database.MainPassword, "backup-export", "--id", id)
	if !exported.OK || exported.BackupDocument == nil || exported.BackupDocument.ID != id {
		t.Fatalf("export: %+v", exported)
	}
	if call(database.MainPassword, "backup-delete", "--id", id, "--confirm", "wrong").OK {
		t.Fatal("delete bypassed confirmation")
	}
	deleted := call(database.MainPassword, "backup-delete", "--id", id, "--confirm", "УДАЛИТЬ")
	if !deleted.OK || deleted.BackupStatus.ValidCount != 1 {
		t.Fatalf("delete: %+v", deleted)
	}
	if status := call(database.MainPassword, "backup-status"); !status.OK || status.BackupStatus.ValidCount != 1 {
		t.Fatalf("status: %+v", status)
	}
}

func TestSimpleBackupKeepsMultipleDeviceBindings(t *testing.T) {
	configDir, database := backupTestConfig(t)
	database.Passwords["ABCDEFGHJKLMNPQR"].DeviceID = "multi"
	database.Passwords["ABCDEFGHJKLMNPQR"].DeviceIDs = []string{"phone", "tablet"}
	database.Passwords["ABCDEFGHJKLMNPQR"].MaxDevices = 2
	summary, err := createServerBackup(configDir, database, "manual")
	if err != nil {
		t.Fatal(err)
	}
	if summary.DeviceCount != 2 {
		t.Fatalf("incorrect device count: %d", summary.DeviceCount)
	}
	document, err := readServerBackupByID(configDir, summary.ID)
	if err != nil || document.DeviceCount != 2 {
		t.Fatalf("read multi-device snapshot: %v", err)
	}
}

func TestSimpleAutomaticBackupRespectsPolicyAndInterval(t *testing.T) {
	configDir, database := backupTestConfig(t)
	previous := db
	db = database
	t.Cleanup(func() { db = previous })
	now := time.Now().Unix()
	if err := runScheduledServerBackup(configDir, now); err != nil {
		t.Fatal(err)
	}
	backups, err := listServerBackups(configDir)
	if err != nil || len(backups) != 0 {
		t.Fatalf("disabled scheduler created a copy: %v", err)
	}
	if _, err := adminBackupConfigure(configDir, database, []string{"--enabled", "true", "--interval-hours", "6", "--retention", "2"}); err != nil {
		t.Fatal(err)
	}
	if err := runScheduledServerBackup(configDir, now); err != nil {
		t.Fatal(err)
	}
	status, err := serverBackupStatusFor(configDir)
	if err != nil || status.ValidCount != 1 {
		t.Fatalf("scheduler ran before interval: %+v %v", status, err)
	}
	state := status.State
	state.LastSuccessAt = now - 7*60*60
	if err := saveServerBackupState(configDir, state); err != nil {
		t.Fatal(err)
	}
	if err := runScheduledServerBackup(configDir, now); err != nil {
		t.Fatal(err)
	}
	status, err = serverBackupStatusFor(configDir)
	if err != nil || status.ValidCount != 2 {
		t.Fatalf("scheduled backup missing: %+v %v", status, err)
	}
	for _, backup := range status.Backups {
		if backup.ID == status.State.LastBackupID && backup.Reason == "scheduled" {
			return
		}
	}
	t.Fatal("the last successful backup was not scheduled")
}

func TestSimpleSnapshotCanBeRestoredByVBridge(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("Python 3 is needed for the VBridge restore integration test")
	}
	configDir, database := backupTestConfig(t)
	database.Passwords["ABCDEFGHJKLMNPQR"].DeviceID = "multi"
	database.Passwords["ABCDEFGHJKLMNPQR"].DeviceIDs = []string{"phone", "tablet"}
	database.Passwords["ABCDEFGHJKLMNPQR"].MaxDevices = 2
	summary, err := createServerBackup(configDir, database, "manual")
	if err != nil {
		t.Fatal(err)
	}
	document, err := readServerBackupByID(configDir, summary.ID)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	script := `import importlib.util, json, sys, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location('migration', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
archive = sys.stdin.read()
files = m.decode_restore_archive(archive, {'target': 'wdtt-simple', 'main_password': 'current-owner'})
database = json.loads(files['passwords.json'])
assert database['main_password'] == 'current-owner'
assert database['passwords']['ABCDEFGHJKLMNPQR']['device_ids'] == ['phone', 'tablet']
assert json.loads(files['backup-policy.json'])['interval_hours'] == 24
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    config = root / 'wdtt'
    config.mkdir()
    (config / 'passwords.json').write_bytes(b'previous database')
    backup = m.restore_files(files, config, root / 'backups', root / 'policy', lambda: None)
    assert (config / 'wg-keys.dat').read_bytes() == files['wg-keys.dat']
    assert (backup / 'passwords.json').read_bytes() == b'previous database'
try:
    m.decode_restore_archive(archive, {'target': 'wdtt-plus', 'main_password': 'owner'})
except ValueError as e:
    assert 'multiple bound devices' in str(e)
else:
    raise AssertionError('multi-device restore to Plus was accepted')
`
	command := exec.Command(python, "-B", "-c", script, filepath.Join("..", "..", "wireguard-apple", "Sources", "WireGuardKitGo", "wdtt_database_migration.py"))
	command.Stdin = strings.NewReader(string(raw))
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("native snapshot -> VBridge restore: %v\n%s", err, output)
	}
}
