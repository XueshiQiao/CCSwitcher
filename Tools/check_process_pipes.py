#!/usr/bin/env python3
"""Run locally with `uv run python3 Tools/check_process_pipes.py` (no dependencies).

Compile real services and exercise their public APIs with a fake CLI. Waiting
before draining stdout, ignoring cancellation, or leaking the CLI fails checks.
No credentials, network requests, persisted preferences, or app logs are used.
"""

import os
from pathlib import Path
import signal
import subprocess
import tempfile


HARNESS = r'''
import Foundation
import Darwin

// The filesystem logging boundary is replaced; all service logic is real.
struct FileLog: Sendable {
    init(_ category: String) {}
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
    func debug(_ message: String) {}
}

@main
struct PipeCheck {
    static func main() async throws {
        let mode = ProcessInfo.processInfo.environment["PIPE_CHECK_CASE"]!
        let ready = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PIPE_CHECK_READY"]!)
        let retry = ready.appendingPathExtension("retry")
        if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "fake-claude" {
            // Foundation may give children their own process group. Rejoin the
            // check runner's group so its watchdog also cleans up this fixture.
            guard setpgid(0, getpgid(getppid())) == 0 else { exit(90) }
            if mode.hasPrefix("cancel-") {
                if FileManager.default.fileExists(atPath: retry.path) { return }
                if mode == "cancel-ignore-term" { signal(SIGTERM, SIG_IGN) }
                if mode == "cancel-zero-exit" { signal(SIGTERM) { _ in exit(0) } }
                var holderPID: Int32 = 0
                if mode == "cancel-inherited-pipe" {
                    let holder = Process()
                    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
                    holder.arguments = ["5"]
                    holder.standardOutput = FileHandle.standardOutput
                    holder.standardError = FileHandle.standardError
                    try holder.run()
                    holderPID = holder.processIdentifier
                }
                try Data("\(getpid()),\(holderPID)".utf8).write(to: ready)
                try await Task.sleep(for: .seconds(30))
                return
            }
            let large = String(repeating: "x", count: 1024 * 1024)
            if mode == "large-stdout" {
                let data = try JSONSerialization.data(withJSONObject: [
                    "loggedIn": true, "email": large + "@example.invalid"
                ])
                FileHandle.standardOutput.write(data)
            } else {
                FileHandle.standardError.write(Data(large.utf8))
                if mode == "large-stderr-failure" { exit(7) }
                FileHandle.standardOutput.write(Data("1.2.3 (fixture)\n".utf8))
            }
            return
        }

        let fixture = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain(
            [kClaudeBinaryPathPreferenceKey: fixture], forName: UserDefaults.argumentDomain)
        let service = ClaudeService.shared
        service.setPath(fixture)
        if mode.hasPrefix("cancel-") {
            let login = Task {
                if mode == "cancel-before-start" {
                    withUnsafeCurrentTask { $0!.cancel() }
                }
                try await service.login { _ in }
            }
            var childPID: Int32 = 0
            var holderPID: Int32 = 0
            if mode != "cancel-before-start" {
                let deadline = Date().addingTimeInterval(3)
                while !FileManager.default.fileExists(atPath: ready.path) {
                    guard Date() < deadline else { fatalError("fake CLI never started") }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pids = try String(contentsOf: ready, encoding: .utf8).split(separator: ",")
                childPID = Int32(pids[0])!
                holderPID = Int32(pids[1])!
                login.cancel()
            }
            defer { if holderPID != 0 { kill(holderPID, SIGKILL) } }
            do {
                try await login.value
                fatalError("cancelled login reported success")
            } catch is CancellationError {}
            if childPID != 0 {
                guard kill(childPID, 0) == -1, errno == ESRCH else {
                    fatalError("cancelled CLI still exists")
                }
            } else {
                guard !FileManager.default.fileExists(atPath: ready.path) else {
                    fatalError("pre-cancelled login launched a CLI")
                }
            }
            try Data().write(to: retry)
            try await service.login { _ in }
            print("PASS: \(mode), child reaped and next login succeeds")
            return
        }
        switch mode {
        case "large-stdout":
            let status = try await service.getAuthStatus()
            guard status.loggedIn,
                  status.email == String(repeating: "x", count: 1024 * 1024) + "@example.invalid"
            else { print("FAIL: large JSON output was truncated"); exit(1) }
        case "large-stderr-failure":
            do {
                _ = try await service.getAuthStatus()
                print("FAIL: expected exit 7 error"); exit(1)
            } catch ClaudeServiceError.cliError(let message) {
                guard message == "exit 7" else { print("FAIL: wrong CLI error"); exit(1) }
            }
        case "version-stderr":
            let version = await ClaudeService.readVersion(at: fixture)
            guard version == "1.2.3" else { print("FAIL: version probe did not drain stderr"); exit(1) }
        default:
            fatalError("Unknown check: \(mode)")
        }
        print("PASS: \(mode)")
    }
}
'''


def main():
    root = Path(__file__).resolve().parent.parent
    sources = [
        "Services/ClaudeService.swift",
        "Services/CancelableProcess.swift",
        "Services/KeychainService.swift",
        "Models/Account.swift",
        "Models/String+Obfuscation.swift",
        "Models/UsageData.swift",
    ]
    failed = False
    with tempfile.TemporaryDirectory(prefix="ccswitcher-pipes-") as directory:
        temp = Path(directory)
        harness = temp / "PipeCheck.swift"
        harness.write_text(HARNESS)
        binary = temp / "pipe-check"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", str(temp / "module-cache"),
            *[str(root / "CCSwitcher" / source) for source in sources],
            str(harness), "-o", str(binary),
        ], check=True)
        fixture = temp / "fake-claude"
        fixture.symlink_to(binary)
        for mode in (
            "large-stdout", "large-stderr-failure", "version-stderr",
            "cancel-before-start", "cancel-running", "cancel-ignore-term",
            "cancel-zero-exit", "cancel-inherited-pipe",
        ):
            env = {
                **os.environ, "PIPE_CHECK_CASE": mode,
                "PIPE_CHECK_READY": str(temp / f"{mode}.ready"),
            }
            with subprocess.Popen(
                [str(binary), str(fixture)], env=env, start_new_session=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            ) as process:
                try:
                    output, _ = process.communicate(timeout=10)
                    print(output.strip(), flush=True)
                    failed |= process.returncode != 0
                except subprocess.TimeoutExpired:
                    failed = True
                    print(f"FAIL: {mode} exceeded 10s (blocked subprocess pipe)", flush=True)
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
