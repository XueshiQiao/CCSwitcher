#!/usr/bin/env python3
"""Offline: uv run python3 Tools/check_cli_usage_bridge.py.

Runs the real helper and installer in a temporary home. Overwriting session
bindings, touching timestamps for repeated CLI output, swallowing the original
status line, or replacing unrelated settings makes this check fail.
"""

import json
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid
from unittest.mock import patch


def main():
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="cli-usage-bridge-check-") as directory:
        home = Path(directory)
        binary = home / "CCSwitcherCLI"
        subprocess.run(["swiftc", "-swift-version", "6", "-module-cache-path", str(home / "modules"),
                        str(repo / "CLIUsageBridge/main.swift"), "-o", str(binary)], check=True, timeout=120)
        config_dir = home / ".claude"
        config_dir.mkdir()
        settings = config_dir / "settings.json"
        original = {"statusLine": {"type": "command", "command": "/bin/cat", "padding": 2, "refreshInterval": 7},
                    "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "printf unchanged"}]}],
                              "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "true"}]}]},
                    "language": "zh-Hans", "env": {"UNRELATED_FLAG": "unchanged"}}
        settings.write_text(json.dumps(original))
        account_a, account_b = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        session_a, session_b = str(uuid.uuid4()), str(uuid.uuid4())
        identity_path = home / ".claude.json"

        def identity(account):
            identity_path.write_text(json.dumps({"oauthAccount": {"accountUuid": account,
                                                                  "emailAddress": account + "@example.invalid"}}))

        installer = [sys.executable, str(repo / "Tools/install_cli_usage_bridge.py")]

        def install(action):
            return subprocess.run(installer + [action, "--home", str(home), "--helper", str(binary)],
                                  capture_output=True, check=True, timeout=10)

        install("install")
        installed = settings.read_bytes()
        install("install")
        assert settings.read_bytes() == installed, "Repeated install changed settings"
        actual = json.loads(installed)
        assert actual["hooks"]["Stop"] == original["hooks"]["Stop"]
        assert actual["hooks"]["SessionStart"][0] == original["hooks"]["SessionStart"][0]
        assert len(actual["hooks"]["SessionStart"]) == 2
        assert actual["statusLine"]["padding"] == 2 and actual["statusLine"]["refreshInterval"] == 7
        assert actual["env"] == original["env"]
        root = home / ".ccswitcher/cli-usage"
        assert json.loads((root / "settings-before-install.json").read_bytes()) == original
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("ANTHROPIC_", "CLAUDE_"))}

        def invoke(mode, session, percentage=None, extra_env=None):
            payload = {"session_id": session, "cwd": str(home)}
            if percentage is not None:
                payload["rate_limits"] = {"five_hour": {"used_percentage": percentage, "resets_at": 2000000000}}
            data = (json.dumps(payload) + "\n").encode()
            result = subprocess.run([str(binary), mode, "--home", str(home)], input=data,
                                    capture_output=True, env={**environment, **(extra_env or {})}, timeout=10)
            if mode == "statusline":
                assert result.stdout == data and result.returncode == 0, "Original statusline stdin/stdout was altered"
            return result

        identity(account_a)
        assert invoke("statusline", session_a, 10).stderr, "Unbound session accepted"
        account_file = root / "accounts" / (account_a + ".json")
        assert not account_file.exists()
        assert invoke("session-start", session_a).returncode == 0
        assert not invoke("statusline", session_a, 10).stderr
        first = account_file.read_bytes()
        assert json.loads(first)["rateLimits"]["five_hour"]["used_percentage"] == 10
        assert "seven_day" not in json.loads(first)["rateLimits"], "Absent windows must be omitted, not null"
        invoke("statusline", session_a, 10)
        assert account_file.read_bytes() == first, "Repeated payload changed observation time"

        invoke("session-start", session_b)
        invoke("statusline", session_b, 20)
        newer = account_file.read_bytes()
        invoke("statusline", session_a, 10)
        assert account_file.read_bytes() == newer, "Another session's repeated old payload replaced current sample"
        invoke("statusline", session_b)
        invoke("statusline", session_b, 101)
        invoke("statusline", session_b, 30, {"ANTHROPIC_API_KEY": "offline-fixture"})
        assert account_file.read_bytes() == newer, "Missing, invalid or ambiguous input changed cache"
        profile = home / ".config/anthropic/configs/default.json"
        profile.parent.mkdir(parents=True)
        profile.write_text("{}")
        assert invoke("statusline", session_b, 30).stderr
        assert account_file.read_bytes() == newer, "Profile credentials were attributed to a subscription account"
        profile.unlink()

        identity(account_b)
        assert invoke("statusline", session_a, 35).stderr
        assert invoke("session-start", session_a).returncode != 0, "Resume rebound session to another account"
        assert not (root / "accounts" / (account_b + ".json")).exists()
        identity(account_a)
        assert invoke("statusline", session_a, 40).stderr, "Invalidated session accepted after switching back"
        assert account_file.read_bytes() == newer

        # Real pipes must also preserve a command that closes stdin immediately.
        manifest_path = root / "installation.json"
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
        manifest["originalCommand"] = "printf kept; exit 7"
        manifest_path.write_text(json.dumps(manifest))
        early = subprocess.run([str(binary), "statusline", "--home", str(home)], input=b"x" * 1024 * 1024,
                               capture_output=True, env=environment, timeout=10)
        assert early.stdout == b"kept" and early.returncode == 7, "Early stdin close lost output or exit code"
        manifest_path.write_bytes(manifest_bytes)

        install("uninstall")
        assert json.loads(settings.read_bytes()) == original, "Uninstall did not preserve original settings"
        assert account_file.exists(), "Uninstall deleted account samples"

        # Fail the filesystem replacement, not an internal collaborator: the
        # settings and manifest must both stay at the pre-install state.
        spec = importlib.util.spec_from_file_location("bridge_install", repo / "Tools/install_cli_usage_bridge.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real_replace = os.replace

        def fail_settings_replace(source, target):
            if Path(target) == settings:
                raise PermissionError("offline simulated settings write failure")
            return real_replace(source, target)

        with patch("os.replace", side_effect=fail_settings_replace):
            try:
                module.run("install", home, binary)
                raise AssertionError("Expected settings replacement to fail")
            except PermissionError:
                pass
        assert not manifest_path.exists(), "Failed install left an active manifest"
        assert json.loads(settings.read_bytes()) == original
        for minimal in [{}, {"hooks": {"SessionStart": []}}]:
            settings.write_text(json.dumps(minimal))
            install("install")
            install("uninstall")
            assert json.loads(settings.read_bytes()) == minimal, "Uninstall changed absent or empty hooks"
        print("PASS: real helper binding, cross-session dedupe, identity rejection, raw passthrough, idempotent install/restore")


if __name__ == "__main__":
    main()
