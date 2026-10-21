"""Prepare a shared WDTT database before changing the installed server.

Executed as root over SSH; credentials arrive on stdin, never in log output.
"""
import copy
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".restore-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def decode_restore_archive(text, settings):
    if len(text.encode()) > 96 << 20:
        raise ValueError("Restore archive is too large")
    archive = json.loads(text)
    if not isinstance(archive, dict):
        raise ValueError("Invalid restore archive")
    files = {}
    limits = {"passwords.json": 64 << 20, "wg-keys.dat": 4096,
              "outbound-profile.env": 2 << 20, "backup-policy.json": 64 << 10}
    if archive.get("format") == "wdtt-plus-state" and archive.get("version") == 1:
        for name, key in (("passwords.json", "passwordsJson"), ("wg-keys.dat", "wgKeysData")):
            files[name] = base64.b64decode(archive.get(key, ""), validate=True)
    elif archive.get("format") == "wdtt-server-snapshot" and archive.get("version") in (1, 2, 3):
        for item in archive.get("files", []):
            name = item.get("path")
            if name not in limits or name in files or item.get("mode") != 0o600:
                raise ValueError("Invalid or duplicate file in restore archive")
            raw = base64.b64decode(item.get("data_b64", ""), validate=True)
            if len(raw) != item.get("size") or hashlib.sha256(raw).hexdigest() != str(item.get("sha256", "")).lower():
                raise ValueError("Restore archive checksum or size does not match")
            files[name] = raw
        if archive["version"] >= 3 and "backup-policy.json" not in files:
            raise ValueError("Restore archive is missing its backup policy")
    else:
        raise ValueError("Unsupported restore archive format")
    for required in ("passwords.json", "wg-keys.dat"):
        if not files.get(required):
            raise ValueError("Restore archive must include the database and server keys")
    if any(not raw or len(raw) > limits[name] for name, raw in files.items()) or sum(map(len, files.values())) > 80 << 20:
        raise ValueError("Restore archive file size exceeds limits")
    database = json.loads(files["passwords.json"])
    if not isinstance(database, dict) or any(not isinstance(database.get(name), dict) for name in ("passwords", "devices")):
        raise ValueError("Invalid client collections in restore archive")
    keys = files["wg-keys.dat"].decode().strip().splitlines()
    if len(keys) != 4 or any(len(base64.b64decode(key.strip(), validate=True)) != 32 for key in keys):
        raise ValueError("Invalid WireGuard keys in restore archive")
    if "backup-policy.json" in files:
        policy = json.loads(files["backup-policy.json"])
        if not isinstance(policy, dict) or not isinstance(policy.get("enabled"), bool):
            raise ValueError("Invalid backup policy in restore archive")
        interval, retention = policy.get("interval_hours"), policy.get("retention_count")
        if type(interval) is not int or not 6 <= interval <= 168 or type(retention) is not int or not 2 <= retention <= 90:
            raise ValueError("Invalid backup policy limits in restore archive")
    # Do not execute any imported outbound environment. The Simple server does
    # not use it; installations that support it retain their current policy.
    files.pop("outbound-profile.env", None)
    files["passwords.json"] = json.dumps(adapt_database(database, settings), ensure_ascii=False, indent=2).encode()
    return files


def restore_files(files, directory, backup_root, policy_root, restart):
    if directory.is_symlink() or not directory.is_dir() or backup_root.is_symlink():
        raise ValueError("Unsafe or missing WDTT restore directory")
    paths = {name: (policy_root if name == "backup-policy.json" else directory) / name for name in files}
    originals = {}
    for name, path in paths.items():
        if path.parent.is_symlink():
            raise ValueError("Unsafe WDTT policy directory")
        if path.exists() or path.is_symlink():
            regular_file(path)
            originals[name] = path.read_bytes()
        else:
            originals[name] = None
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(backup_root, 0o700)
    backup = Path(tempfile.mkdtemp(prefix="before-restore-", dir=backup_root))
    for name, raw in originals.items():
        if raw is not None:
            atomic_write(backup / name, raw)
    for path in paths.values():
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        for name, raw in files.items():
            atomic_write(paths[name], raw)
        restart()
    except Exception:
        # Stop a server that may already be using the restored state before
        # putting back the database and keys from the same previous generation.
        subprocess.run(["systemctl", "stop", "wdtt"], capture_output=True)
        for name, raw in originals.items():
            if raw is None:
                paths[name].unlink(missing_ok=True)
            else:
                atomic_write(paths[name], raw)
        raise
    return backup


def restart_restored_server():
    subprocess.run(["systemctl", "restart", "wdtt"], capture_output=True, check=True)
    for _ in range(40):
        active = subprocess.run(["systemctl", "is-active", "--quiet", "wdtt"], capture_output=True).returncode == 0
        interface = subprocess.run(["ip", "link", "show", "wdtt0"], capture_output=True).returncode == 0
        if active and interface:
            return
        time.sleep(0.5)
    raise ValueError("Restored WDTT did not become ready; previous database and keys restored")


def adapt_database(original, settings):
    if settings.get("target") not in ("wdtt-simple", "wdtt", "wdtt-plus"):
        raise ValueError("Unsupported WDTT migration target")
    if not isinstance(original, dict):
        raise ValueError("WDTT database must be a JSON object")
    data = copy.deepcopy(original)
    for name in ("passwords", "devices"):
        if name not in data:
            data[name] = {}
        if not isinstance(data[name], dict):
            raise ValueError("Invalid WDTT database field: " + name)
        for key, entry in data[name].items():
            if not key or not isinstance(entry, dict):
                raise ValueError("Invalid WDTT database entry in " + name)
    for name in ("main_password", "admin_id", "bot_token"):
        value = settings.get(name) or data.get(name) or ""
        if not isinstance(value, str):
            raise ValueError("Invalid WDTT database field: " + name)
        data[name] = value
    if not data["main_password"].strip():
        raise ValueError("Main WDTT password is required; database left unchanged")
    for entry in data["passwords"].values():
        device = entry.get("device_id") or ""
        devices = entry.get("device_ids") or []
        if not isinstance(device, str) or not isinstance(devices, list):
            raise ValueError("Invalid WDTT device binding")
        if any(not isinstance(item, str) or not item or item == "multi" for item in devices):
            raise ValueError("Invalid WDTT device binding")
        devices = list(dict.fromkeys(devices))
        if device and device != "multi" and device not in devices:
            devices.append(device)
        if device == "multi" and not devices:
            raise ValueError("Missing WDTT device_ids for a multi-device binding")
        if not entry.get("label") and entry.get("marker"):
            entry["label"] = entry["marker"]
        if settings["target"] in ("wdtt", "wdtt-plus"):
            if len(devices) > 1:
                raise ValueError("Cannot migrate to WDTT/WDTT Plus: an access password has multiple bound devices. Create separate accesses or unbind extra devices first; database left unchanged")
            entry["device_id"] = devices[0] if devices else ""
            entry.pop("device_ids", None)
            entry.pop("max_devices", None)
        else:
            entry["device_ids"] = devices
            entry["device_id"] = "multi" if len(devices) > 1 else (devices[0] if devices else "")
            limit = entry.get("max_devices", 1)
            if not isinstance(limit, int) or isinstance(limit, bool):
                raise ValueError("Invalid WDTT max_devices")
            entry["max_devices"] = max(1, limit, len(devices))
    return data


def regular_file(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Unsafe WDTT configuration file: " + path.name)


def migrate(settings, directory, backup_root):
    if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
        raise ValueError("Unsafe WDTT configuration directory")
    path = directory / "passwords.json"
    original = {}
    if path.exists() or path.is_symlink():
        regular_file(path)
        original = json.loads(path.read_text())
        if not isinstance(original, dict) or any(name not in original for name in ("passwords", "devices")):
            raise ValueError("WDTT database is missing client collections; database left unchanged")
    # Validate the full conversion before creating backups or replacing data.
    data = adapt_database(original, settings)
    keys = directory / "wg-keys.dat"
    if keys.exists() or keys.is_symlink():
        regular_file(keys)
    if backup_root.is_symlink():
        raise ValueError("Unsafe WDTT backup directory")
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(backup_root, 0o700)
    backup = Path(tempfile.mkdtemp(prefix="before-" + settings["target"] + "-", dir=backup_root))
    for source in (path, keys):
        if source.exists():
            destination = backup / source.name
            shutil.copyfile(source, destination)
            os.chmod(destination, 0o600)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".passwords-", dir=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return backup


def main():
    os.umask(0o077)
    settings = json.load(sys.stdin)
    files = decode_restore_archive(settings["archive"], settings) if settings.get("archive") else None
    # Prevent the old process from overwriting a migrated database on exit.
    active = subprocess.run(["systemctl", "is-active", "--quiet", "wdtt"]).returncode == 0
    stopped = subprocess.run(["systemctl", "stop", "wdtt"], capture_output=True)
    if stopped.returncode and subprocess.run(
        ["systemctl", "show", "wdtt", "--property=LoadState", "--value"],
        capture_output=True, text=True,
    ).stdout.strip() != "not-found":
        raise ValueError("Cannot stop WDTT safely; database left unchanged")
    try:
        if files is not None:
            policy_directory = "simple" if settings["target"] == "wdtt-simple" else "user"
            backup = restore_files(files, Path("/etc/wdtt"), Path("/etc/vbridge-backups/wdtt"),
                                   Path("/var/lib/wdtt-server-installer/backups") / policy_directory, restart_restored_server)
        else:
            backup = migrate(settings, Path("/etc/wdtt"), Path("/etc/vbridge-backups/wdtt"))
    except Exception:
        if active:
            subprocess.run(["systemctl", "start", "wdtt"], capture_output=True)
        raise
    print(("WDTT state restored for " if files is not None else "WDTT database prepared for ") + settings["target"] + "; backup: " + str(backup))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # JSON/parser exceptions must not echo database or credential contents.
        message = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else "Invalid or unreadable WDTT database; migration stopped"
        print("WDTT migration failed: " + message, file=sys.stderr)
        sys.exit(1)
