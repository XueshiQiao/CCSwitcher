#!/usr/bin/env python3
"""Offline login regression: uv run python3 Tools/check_login_url.py.

Fails if login opens the default browser, exposes the manual-code fallback URL,
waits for process exit before delivering the URL, or stops cancelling the CLI.
Only a temporary fake CLI runs; no authentication or network calls are made.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

HARNESS = r'''
import Foundation

struct FileLog: Sendable {
    init(_ category: String) {}
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
    func debug(_ message: String) {}
}

actor URLRecorder {
    var value: URL?
    func capture(_ url: URL) { value = url }
}

@main struct Check {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["LOGIN_CHECK_DIR"]!)
        let mode = env["LOGIN_CHECK_MODE"]!
        UserDefaults.standard.set(root.appendingPathComponent("claude").path,
                                  forKey: kClaudeBinaryPathPreferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: kClaudeBinaryPathPreferenceKey) }
        let recorder = URLRecorder()
        let login = Task {
            try await ClaudeService.shared.login { await recorder.capture($0) }
        }
        if mode == "success" || mode == "cancel" {
            let deadline = Date().addingTimeInterval(5)
            while await recorder.value == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let value = await recorder.value
            precondition(value?.absoluteString == "https://claude.ai/oauth/authorize?state=offline&redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback")
            if mode == "cancel" {
                login.cancel()
                do { try await login.value; preconditionFailure("Cancellation succeeded") }
                catch is CancellationError {}
            } else {
                try Data().write(to: root.appendingPathComponent("finish"))
                try await login.value
            }
        } else {
            do { try await login.value; preconditionFailure("Invalid login succeeded") }
            catch let error as ClaudeServiceError {
                if mode == "bad-url" {
                    precondition(error.localizedDescription.contains("Invalid login authorization URL"))
                }
            }
            let value = await recorder.value
            precondition(value == nil)
        }
        let helper = try String(contentsOf: root.appendingPathComponent("helper"), encoding: .utf8)
        precondition(!FileManager.default.fileExists(atPath: helper))
        print("PASS login URL \(mode)")
    }
}
'''
FAKE_CLI = r'''#!/bin/sh
set -eu
printf '%s' "$BROWSER" > "$LOGIN_CHECK_DIR/helper"
if [ "$LOGIN_CHECK_MODE" = early-failure ]; then exit 9; fi
printf 'If browser did not open, visit: https://claude.ai/manual-code-fallback\n'
if [ "$LOGIN_CHECK_MODE" = bad-url ]; then
    "$BROWSER" 'javascript:alert(1)'
else
    "$BROWSER" 'https://claude.ai/oauth/authorize?state=offline&redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback'
fi
while [ ! -f "$LOGIN_CHECK_DIR/finish" ]; do /bin/sleep 0.1; done
'''


def main():
    root = Path(__file__).resolve().parent.parent
    sources = [
        "Services/ClaudeService.swift",
        "Services/CancelableProcess.swift", "Services/KeychainService.swift",
        "Models/Account.swift", "Models/String+Obfuscation.swift", "Models/UsageData.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="login-url-check-") as directory:
        work = Path(directory)
        harness = work / "Check.swift"
        harness.write_text(HARNESS)
        binary = work / ("login-check-" + uuid.uuid4().hex)
        subprocess.run([
            "swiftc", "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", str(work / "modules"),
            *[str(root / "CCSwitcher" / source) for source in sources],
            str(harness), "-o", str(binary),
        ], check=True, timeout=120)
        for mode in ["success", "cancel", "bad-url", "early-failure"]:
            case = work / mode
            case.mkdir()
            cli = case / "claude"
            cli.write_text(FAKE_CLI)
            cli.chmod(0o700)
            subprocess.run([str(binary)], check=True, timeout=10, env={
                **os.environ, "LOGIN_CHECK_DIR": str(case), "LOGIN_CHECK_MODE": mode,
            })


if __name__ == "__main__":
    main()
