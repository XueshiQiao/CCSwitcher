#!/usr/bin/env python3
"""Offline shell boundary check; never opens Terminal or invokes the real CLI.

Fails if quoting permits command injection, changed identity/authentication runs
Claude anyway, or the temporary launcher is left behind after exit.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile

HARNESS = r'''
import Foundation
enum L10n { static let bundle = Bundle.main }
@main struct Check {
    static func main() throws {
        let args = CommandLine.arguments
        print(try CLIUsageSession.prepare(claudePath: args[1], home: URL(fileURLWithPath: args[2]),
              accountUuid: args[3], email: args[4]).path)
    }
}
'''


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="cli-session-check-") as temporary:
        folder = Path(temporary)
        harness = folder / "main.swift"
        harness.write_text(HARNESS)
        executable = folder / "check"
        subprocess.run(["swiftc", "-swift-version", "6", "-module-cache-path", "/private/tmp/ccswitcher-bridge-modules", "-parse-as-library", str(root / "CCSwitcher/Services/CLIUsageSession.swift"),
                        str(harness), "-o", str(executable)], check=True)
        home = folder / "home ' quoted $(touch INJECTION)"
        home.mkdir()
        cli = home / "fake ' claude"
        cli.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$@" > "$HOME/result"\nexit 7\n')
        cli.chmod(0o700)
        account = "11111111-1111-4111-8111-111111111111"
        email = "quote'$(touch INJECTION)@example.invalid"
        config = home / ".claude.json"
        identity = {"oauthAccount": {"accountUuid": account, "emailAddress": email}}
        config.write_text(json.dumps(identity))
        clean = {k: v for k, v in os.environ.items() if not k.startswith(("ANTHROPIC_", "CLAUDE_"))}
        clean["HOME"] = str(home)

        def prepare():
            result = subprocess.run([str(executable), str(cli), str(home), account, email],
                                    env=clean, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            script = Path(result.stdout.strip())
            assert script.stat().st_mode & 0o777 == 0o700
            assert script.parent.stat().st_mode & 0o777 == 0o700
            return script

        def run(script, env):
            result = subprocess.run(["/bin/sh", str(script)], env=env, capture_output=True, text=True)
            assert not script.exists() and not script.parent.exists()
            return result

        result = run(prepare(), clean)
        assert result.returncode == 7, result.stderr
        assert (home / "result").read_text().splitlines() == [str(home), "--safe-mode", "/usage"]
        assert not (home / "INJECTION").exists()
        (home / "result").unlink()
        for override in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR",
                         "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"]:
            result = run(prepare(), dict(clean, **{override: "fixture-override"}))
            assert result.returncode != 0 and not (home / "result").exists()
        script = prepare()
        config.write_text(json.dumps({"oauthAccount": {"accountUuid": account, "emailAddress": "other@example.invalid"}}))
        result = run(script, clean)
        assert result.returncode != 0 and not (home / "result").exists()
        config.write_text(json.dumps(identity))
        settings = home / ".claude/settings.json"
        settings.parent.mkdir()
        script = prepare()
        alternate = settings.parent / ".credentials.json"
        alternate.write_text("{}")
        result = run(script, clean)
        assert result.returncode != 0 and not (home / "result").exists()
        alternate.unlink()
        for value in [{"apiKeyHelper": "fixture"}, {"env": {"ANTHROPIC_BASE_URL": "fixture"}}]:
            settings.write_text(json.dumps(value))
            result = subprocess.run([str(executable), str(cli), str(home), account, email], env=clean,
                                    capture_output=True, text=True)
            assert result.returncode != 0
        print("PASS: visible CLI launcher quoting, identity/auth guards, cleanup; no real CLI or Terminal opened")


if __name__ == "__main__":
    main()
