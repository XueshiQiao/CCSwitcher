#!/usr/bin/env python3
"""Manage the legacy standalone CLI quota collector without replacing hooks.

CCSwitcher now reads the official CLI cache directly. This collector is not
bundled with the app; install requires an explicitly built --helper executable.

Run with uv run python3 Tools/install_cli_usage_bridge.py install --helper PATH.
--home selects the Claude user configuration home (defaults to the current home).
No accounts, credentials, or network endpoints are accessed.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import tempfile


def write_atomic(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix=".bridge-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def run(action, home, helper):
    root = home / ".ccswitcher/cli-usage"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    settings = home / ".claude/settings.json"
    manifest_path = root / "installation.json"
    with (root / ".install.lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = settings.read_bytes() if settings.exists() else b"{}\n"
        value = json.loads(before)
        if not isinstance(value, dict):
            raise ValueError("Claude settings must be a JSON object")
        had_hooks = "hooks" in value
        hooks = value.setdefault("hooks", {})
        if not isinstance(hooks, dict):
            raise ValueError("Claude hooks must be a JSON object")
        existing = hooks.get("SessionStart", [])
        if not isinstance(existing, list):
            raise ValueError("SessionStart hooks must be an array")
        previous_manifest = manifest_path.read_bytes() if manifest_path.exists() else None
        manifest = json.loads(previous_manifest) if previous_manifest else None
        if manifest and manifest["version"] != 1:
            raise ValueError("Unsupported bridge installation version")
        if manifest:
            if value.get("statusLine") != manifest["installedStatusLine"] or manifest["hook"] not in existing:
                raise ValueError("Bridge settings were edited externally; refusing to overwrite them")
            original = manifest["originalStatusLine"]
        else:
            if action == "uninstall":
                raise ValueError("No installed bridge was found")
            original = value.get("statusLine")
            if original is not None and (not isinstance(original, dict) or original.get("type") != "command"
                                         or not isinstance(original.get("command"), str)):
                raise ValueError("Unsupported existing statusLine configuration")
            if original and "CCSwitcherCLI" in original["command"]:
                raise ValueError("An existing bridge command has no installation manifest; refusing recursive wrapping")
            # Preserve exact bytes, including unrelated settings, as a manual rollback.
            write_atomic(root / "settings-before-install.json", before)

        if action == "install":
            helper = helper.resolve(strict=True)
            if not os.access(helper, os.X_OK):
                raise ValueError("CLI collector is not executable")
            command = shlex.join([str(helper), "statusline", "--home", str(home)])
            hook = {"hooks": [{"type": "command", "command": shlex.join(
                [str(helper), "session-start", "--home", str(home)])}]}
            status_line = dict(original or {})
            status_line.update(type="command", command=command)
            new_manifest = {"version": 1, "originalCommand": original["command"] if original else None,
                            "originalStatusLine": original, "installedStatusLine": status_line, "hook": hook,
                            "originalHadHooks": manifest["originalHadHooks"] if manifest else had_hooks,
                            "originalHadSessionStart": manifest["originalHadSessionStart"] if manifest else "SessionStart" in hooks}
            value["statusLine"] = status_line
            hooks["SessionStart"] = [entry for entry in existing if not manifest or entry != manifest["hook"]] + [hook]
        else:
            if original is None:
                value.pop("statusLine", None)
            else:
                value["statusLine"] = original
            remaining = [entry for entry in existing if entry != manifest["hook"]]
            if remaining or manifest["originalHadSessionStart"]:
                hooks["SessionStart"] = remaining
            else:
                hooks.pop("SessionStart", None)
            if not hooks and not manifest["originalHadHooks"]:
                value.pop("hooks")

        # Check again immediately before replacing so known concurrent edits are not lost.
        current = settings.read_bytes() if settings.exists() else b"{}\n"
        if current != before:
            raise ValueError("Claude settings changed during installation; no settings were overwritten")
        settings.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if action == "install":
            write_atomic(manifest_path, encode(new_manifest))
        try:
            current = settings.read_bytes() if settings.exists() else b"{}\n"
            if current != before:
                raise ValueError("Claude settings changed during installation; no settings were overwritten")
            write_atomic(settings, encode(value))
        except BaseException:
            if action == "install":
                if previous_manifest is None:
                    manifest_path.unlink()
                else:
                    write_atomic(manifest_path, previous_manifest)
            raise
        if action == "uninstall":
            manifest_path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--helper", type=Path)
    args = parser.parse_args()
    if args.action == "install" and args.helper is None:
        parser.error("install requires --helper; the legacy collector is not bundled with CCSwitcher")
    run(args.action, args.home.expanduser().resolve(), args.helper)
    print("CLI usage bridge " + ("installed; start a new Claude session" if args.action == "install" else "removed; original status line restored"))


if __name__ == "__main__":
    main()
