import copy
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "wireguard-apple/Sources/WireGuardKitGo/wdtt_database_migration.py"
spec = importlib.util.spec_from_file_location("migration", SOURCE)
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def settings(self, target="wdtt-plus"):
        return {"target": target, "main_password": "owner", "admin_id": "", "bot_token": ""}

    def database(self):
        return {"passwords": {"client": {"device_id": "phone", "expires_at": 1234, "down_bytes": 17}},
                "devices": {"phone": {"device_id": "phone", "ip": "10.66.66.2", "priv_key": "private", "pub_key": "public"}}}

    def test_repairs_reported_missing_main_password(self):
        source = self.database()
        saved = copy.deepcopy(source)
        result = migration.adapt_database(source, self.settings())
        self.assertEqual(result["main_password"], "owner")
        self.assertEqual(result["devices"], source["devices"])
        self.assertEqual(source, saved)

    def test_plus_to_standard_to_plus_preserves_access_and_keys(self):
        source = self.database()
        source["main_password"] = "owner"
        standard = migration.adapt_database(source, self.settings("wdtt-simple"))
        self.assertEqual(standard["passwords"]["client"]["device_ids"], ["phone"])
        self.assertEqual(standard["passwords"]["client"]["max_devices"], 1)
        plus = migration.adapt_database(standard, self.settings())
        self.assertEqual(plus["passwords"], source["passwords"])
        self.assertEqual(plus["devices"], source["devices"])

    def test_multi_device_to_plus_is_rejected_without_modifying_source(self):
        source = self.database()
        source["passwords"]["client"].update(device_id="multi", device_ids=["phone", "tablet"])
        saved = copy.deepcopy(source)
        with self.assertRaisesRegex(ValueError, "multiple bound devices"):
            migration.adapt_database(source, self.settings())
        self.assertEqual(source, saved)

    def test_single_device_and_marker_are_mapped(self):
        source = self.database()
        source["passwords"]["client"].update(device_id="multi", device_ids=["phone"], marker="My phone")
        result = migration.adapt_database(source, self.settings())
        self.assertEqual(result["passwords"]["client"]["device_id"], "phone")
        self.assertEqual(result["passwords"]["client"]["label"], "My phone")

    def test_all_three_variants_preserve_single_device_access(self):
        for origin in ("wdtt-simple", "wdtt", "wdtt-plus"):
            for target in ("wdtt-simple", "wdtt", "wdtt-plus"):
                with self.subTest(origin=origin, target=target):
                    source = migration.adapt_database(self.database(), self.settings(origin))
                    result = migration.adapt_database(source, self.settings(target))
                    self.assertEqual(result["main_password"], "owner")
                    self.assertEqual(result["devices"], source["devices"])
                    self.assertEqual(result["passwords"]["client"]["device_id"], "phone")
                    self.assertEqual(result["passwords"]["client"]["expires_at"], 1234)
                    self.assertEqual(result["passwords"]["client"]["down_bytes"], 17)

    def test_both_extended_variants_reject_multiple_devices(self):
        source = self.database()
        source["passwords"]["client"].update(device_id="multi", device_ids=["phone", "tablet"])
        for target in ("wdtt", "wdtt-plus"):
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "multiple bound devices"):
                migration.adapt_database(source, self.settings(target))

    def test_blank_optional_settings_preserve_existing_credentials(self):
        source = self.database()
        source.update(admin_id="admin", bot_token="token")
        result = migration.adapt_database(source, self.settings())
        self.assertEqual(result["admin_id"], "admin")
        self.assertEqual(result["bot_token"], "token")

    def test_invalid_structures_and_bindings_fail(self):
        for invalid in ([], {"passwords": []}, {"devices": None},
                        {"passwords": {"client": None}},
                        {"passwords": {"client": {"device_id": "multi"}}},
                        {"passwords": {"client": {"device_ids": [5]}}}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                migration.adapt_database(invalid, self.settings())

    def test_backup_is_exact_and_keys_are_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "wdtt"
            directory.mkdir()
            raw = json.dumps(self.database()).encode()
            (directory / "passwords.json").write_bytes(raw)
            (directory / "wg-keys.dat").write_bytes(b"server keys")
            backup = migration.migrate(self.settings(), directory, root / "backups")
            self.assertEqual((backup / "passwords.json").read_bytes(), raw)
            self.assertEqual((backup / "wg-keys.dat").read_bytes(), b"server keys")
            self.assertEqual((directory / "wg-keys.dat").read_bytes(), b"server keys")
            self.assertEqual(stat.S_IMODE((directory / "passwords.json").stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((backup / "passwords.json").stat().st_mode), 0o600)

    def test_invalid_existing_database_is_never_replaced(self):
        for raw in (b"{broken", b"{}", b'{"passwords":null,"devices":{}}'):
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory = root / "wdtt"
                directory.mkdir()
                path = directory / "passwords.json"
                path.write_bytes(raw)
                with self.assertRaises(ValueError):
                    migration.migrate(self.settings(), directory, root / "backups")
                self.assertEqual(path.read_bytes(), raw)
                self.assertFalse((root / "backups").exists())

    def test_fresh_install_creates_complete_database(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "wdtt"
            migration.migrate(self.settings(), directory, root / "backups")
            data = json.loads((directory / "passwords.json").read_text())
            self.assertEqual(data["main_password"], "owner")
            self.assertEqual(data["passwords"], {})
            self.assertEqual(data["devices"], {})

    def test_symlink_database_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.write_text(json.dumps(self.database()))
            directory = root / "wdtt"
            directory.mkdir()
            (directory / "passwords.json").symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                migration.migrate(self.settings(), directory, root / "backups")

    def test_migration_failure_restarts_previously_running_server(self):
        success = subprocess.CompletedProcess([], 0)
        with patch.object(migration.sys, "stdin", io.StringIO(json.dumps(self.settings()))), \
             patch.object(migration.os, "umask"), \
             patch.object(migration.subprocess, "run", return_value=success) as run, \
             patch.object(migration, "migrate", side_effect=ValueError("invalid")):
            with self.assertRaises(ValueError):
                migration.main()
            self.assertEqual(run.call_args_list[0].args[0], ["systemctl", "is-active", "--quiet", "wdtt"])
            self.assertEqual(run.call_args_list[1].args[0], ["systemctl", "stop", "wdtt"])
            self.assertEqual(run.call_args_list[-1].args[0], ["systemctl", "start", "wdtt"])


class RestoreTests(unittest.TestCase):
    def settings(self, target="wdtt-simple"):
        return {"target": target, "main_password": "current-owner"}

    def archive(self):
        database = {"main_password": "archived-owner", "passwords": {"client": {"device_id": "phone"}}, "devices": {"phone": {"priv_key": "client-key"}}}
        key = base64.b64encode(bytes(32)).decode()
        files = {"passwords.json": json.dumps(database).encode(), "wg-keys.dat": ((key + "\n") * 4).encode(),
                 "backup-policy.json": json.dumps({"enabled": True, "interval_hours": 12, "retention_count": 3}).encode()}
        return {"format": "wdtt-server-snapshot", "version": 3, "files": [
            {"path": name, "mode": 0o600, "size": len(raw), "data_b64": base64.b64encode(raw).decode(),
             "sha256": hashlib.sha256(raw).hexdigest()} for name, raw in files.items()]}

    def test_snapshot_restore_adapts_to_simple(self):
        files = migration.decode_restore_archive(json.dumps(self.archive()), self.settings())
        database = json.loads(files["passwords.json"])
        self.assertEqual(database["main_password"], "current-owner")
        self.assertEqual(database["passwords"]["client"]["device_ids"], ["phone"])
        self.assertEqual(database["devices"]["phone"]["priv_key"], "client-key")

    def test_snapshot_checksum_and_unsafe_paths_are_rejected(self):
        for field, value in (("path", "../passwords.json"), ("sha256", "bad"), ("size", 1), ("mode", 0o644)):
            archive = self.archive()
            archive["files"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                migration.decode_restore_archive(json.dumps(archive), self.settings())

    def test_legacy_state_restore_remains_supported(self):
        entries = {f["path"]: f["data_b64"] for f in self.archive()["files"]}
        archive = {"format": "wdtt-plus-state", "version": 1, "passwordsJson": entries["passwords.json"], "wgKeysData": entries["wg-keys.dat"]}
        files = migration.decode_restore_archive(json.dumps(archive), self.settings())
        self.assertEqual(set(files), {"passwords.json", "wg-keys.dat"})

    def test_simple_multi_device_restore_to_plus_is_rejected(self):
        archive = self.archive()
        entry = archive["files"][0]
        database = json.loads(base64.b64decode(entry["data_b64"]))
        database["passwords"]["client"].update(device_id="multi", device_ids=["phone", "tablet"])
        raw = json.dumps(database).encode()
        entry.update(data_b64=base64.b64encode(raw).decode(), size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
        with self.assertRaisesRegex(ValueError, "multiple bound devices"):
            migration.decode_restore_archive(json.dumps(archive), self.settings("wdtt-plus"))

    def test_restore_installs_database_keys_policy_and_keeps_previous_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "wdtt"
            directory.mkdir()
            (directory / "passwords.json").write_bytes(b"old database")
            (directory / "wg-keys.dat").write_bytes(b"old keys")
            files = migration.decode_restore_archive(json.dumps(self.archive()), self.settings())
            restarted = []
            backup = migration.restore_files(files, directory, root / "backups", root / "policy", lambda: restarted.append(True))
            self.assertEqual(restarted, [True])
            self.assertEqual((directory / "passwords.json").read_bytes(), files["passwords.json"])
            self.assertEqual((directory / "wg-keys.dat").read_bytes(), files["wg-keys.dat"])
            self.assertEqual((root / "policy/backup-policy.json").read_bytes(), files["backup-policy.json"])
            self.assertEqual((backup / "passwords.json").read_bytes(), b"old database")
            self.assertEqual((backup / "wg-keys.dat").read_bytes(), b"old keys")
            self.assertEqual(stat.S_IMODE((directory / "passwords.json").stat().st_mode), 0o600)

    def test_failed_restart_rolls_back_database_keys_and_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "wdtt"
            directory.mkdir()
            for name in ("passwords.json", "wg-keys.dat"):
                (directory / name).write_bytes(("old " + name).encode())
            files = migration.decode_restore_archive(json.dumps(self.archive()), self.settings())
            def fail():
                raise ValueError("restart failed")
            with patch.object(migration.subprocess, "run"), self.assertRaisesRegex(ValueError, "restart failed"):
                migration.restore_files(files, directory, root / "backups", root / "policy", fail)
            for name in ("passwords.json", "wg-keys.dat"):
                self.assertEqual((directory / name).read_bytes(), ("old " + name).encode())
            self.assertFalse((root / "policy/backup-policy.json").exists())


if __name__ == "__main__":
    unittest.main()
