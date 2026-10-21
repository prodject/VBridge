"""Prepare a shared WDTT database before changing the installed server.

Executed as root over SSH; credentials arrive on stdin, never in log output.
"""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def adapt_database(original, settings):
    if settings.get("target") not in ("wdtt", "wdtt-plus"):
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
        if settings["target"] == "wdtt-plus":
            if len(devices) > 1:
                raise ValueError("Cannot migrate to WDTT Plus: an access password has multiple bound devices. Create separate accesses or unbind extra devices first; database left unchanged")
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
    # Prevent the old process from overwriting a migrated database on exit.
    active = subprocess.run(["systemctl", "is-active", "--quiet", "wdtt"]).returncode == 0
    stopped = subprocess.run(["systemctl", "stop", "wdtt"], capture_output=True)
    if stopped.returncode and subprocess.run(
        ["systemctl", "show", "wdtt", "--property=LoadState", "--value"],
        capture_output=True, text=True,
    ).stdout.strip() != "not-found":
        raise ValueError("Cannot stop WDTT safely; database left unchanged")
    try:
        backup = migrate(settings, Path("/etc/wdtt"), Path("/etc/vbridge-backups/wdtt"))
    except Exception:
        if active:
            subprocess.run(["systemctl", "start", "wdtt"], capture_output=True)
        raise
    print("WDTT database prepared for " + settings["target"] + "; backup: " + str(backup))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # JSON/parser exceptions must not echo database or credential contents.
        message = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else "Invalid or unreadable WDTT database; migration stopped"
        print("WDTT migration failed: " + message, file=sys.stderr)
        sys.exit(1)
