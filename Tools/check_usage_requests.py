#!/usr/bin/env python3
"""Offline check: uv run python3 Tools/check_usage_requests.py.

Reintroducing a global lock/cooldown, delaying persistence until success, retrying
429, or truncating Retry-After makes this check fail. URLProtocol intercepts every request;
the unique executable has its own preferences domain and uses only a dummy token.
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

final class Fixture: @unchecked Sendable {
    static let shared = Fixture()
    let lock = NSLock()
    private var count = 0
    func start() { lock.lock(); count += 1; lock.unlock() }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Fixture.shared.start()
        precondition(request.url!.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-fixture")
        Thread.sleep(forTimeInterval: 0.2)
        let mode = ProcessInfo.processInfo.environment["USAGE_CHECK_CASE"]!
        var headers: [String: String] = [:]
        var status = 200
        if mode.hasPrefix("rate-") {
            status = 429
            if mode == "rate-seconds" { headers["Retry-After"] = "14400" }
            if mode == "rate-date" {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                headers["Retry-After"] = formatter.string(from: Date().addingTimeInterval(14400))
            }
            if mode == "rate-infinity" { headers["Retry-After"] = "inf" }
            if mode == "rate-overflow" { headers["Retry-After"] = "1e300" }
            if mode == "rate-invalid-date" { headers["Retry-After"] = "not a date" }
        }
        if mode == "expired" { status = 401 }
        if mode == "network-failure" { status = 503 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Data("{\"five_hour\":{\"utilization\":23}}".utf8))
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct UsageCheck {
    static func main() async throws {
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        precondition(URLProtocol.registerClass(OfflineProtocol.self))
        let mode = ProcessInfo.processInfo.environment["USAGE_CHECK_CASE"]!
        let account = UUID(uuidString: "920A0CB9-A5AE-4E11-BD42-EF213DB54286")!
        let gate = UsageRequestLimiter.shared
        let domain = ProcessInfo.processInfo.processName
        defer {
            if mode != "persist-write" {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
        }
        if mode == "persist-read" {
            let date = try await gate.nextAllowedDate(for: account)!
            precondition(date.timeIntervalSinceNow > 800)
            do {
                _ = try await gate.getUsageLimits(accessToken: "offline-fixture", accountID: account)
                fatalError("Restart bypassed persisted cooldown")
            } catch UsageRequestLimiter.RequestError.cooldown { }
            precondition(Fixture.shared.requests == 0)
            print("PASS: persisted cooldown survives a new process")
            return
        }

        // Stale preferences from the previous version must not block any account.
        UserDefaults.standard.set(Date().addingTimeInterval(3600).timeIntervalSince1970,
                                  forKey: "usageRequestGlobalDeadline")
        let request = Task {
            try await gate.getUsageLimits(accessToken: "offline-fixture", accountID: account)
        }
        for _ in 0..<100 where Fixture.shared.requests == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        precondition(Fixture.shared.requests == 1, "Offline transport did not start")
        do {
            _ = try await gate.getUsageLimits(accessToken: "offline-fixture", accountID: account)
            fatalError("Duplicate request admitted while in flight")
        } catch UsageRequestLimiter.RequestError.busy { }
        let otherRequest = Task {
            try await gate.getUsageLimits(accessToken: "offline-fixture", accountID: UUID())
        }
        try await checkResponse(request, mode: mode)
        try await checkResponse(otherRequest, mode: mode)
        precondition(Fixture.shared.requests == 2, "Another account was blocked while the first was in flight")

        let next = try await gate.nextAllowedDate(for: account)!
        let remaining = next.timeIntervalSinceNow
        precondition(remaining > 890, "Failures must consume the account interval")
        if mode == "rate-seconds" || mode == "rate-date" {
            precondition(remaining > 14390, "Server's long Retry-After was shortened")
        }
        if mode == "rate-overflow" { precondition(next == .distantFuture) }
        do {
            _ = try await ClaudeService.shared.getUsageLimits(accessToken: "offline-fixture", accountID: account)
            fatalError("Account cooldown bypassed")
        } catch UsageRequestLimiter.RequestError.cooldown { }
        precondition(Fixture.shared.requests == 2, "Unexpected retry reached transport")
        let independentRequest = Task {
            try await ClaudeService.shared.getUsageLimits(accessToken: "offline-fixture", accountID: UUID())
        }
        try await checkResponse(independentRequest, mode: mode)
        precondition(Fixture.shared.requests == 3, "Another account was blocked by a cooldown")
        precondition(UserDefaults.standard.synchronize())
        print("PASS: \(mode); per-account in-flight deduplication and cooldown; other accounts remain available")
    }

    static func checkResponse(_ request: Task<UsageAPIResponse, Error>, mode: String) async throws {
        do {
            let usage = try await request.value
            precondition(mode == "success" || mode == "persist-write")
            precondition(usage.fiveHour?.utilization == 23)
        } catch ClaudeService.UsageError.rateLimited {
            precondition(mode.hasPrefix("rate-"))
        } catch ClaudeService.UsageError.expired {
            precondition(mode == "expired")
        } catch ClaudeService.UsageError.network {
            precondition(mode == "network-failure")
        }
    }
}
'''


def main():
    root = Path(__file__).resolve().parent.parent
    sources = [
        "Services/UsageRequestLimiter.swift", "Services/ClaudeService.swift",
        "Services/CancelableProcess.swift",
        "Services/KeychainService.swift", "Models/Account.swift",
        "Models/String+Obfuscation.swift", "Models/UsageData.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="usage-request-check-") as directory:
        work = Path(directory)
        harness = work / "Check.swift"
        harness.write_text(HARNESS)
        binary = work / ("usage-check-" + uuid.uuid4().hex)
        subprocess.run([
            "swiftc", "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", str(work / "modules"),
            *[str(root / "CCSwitcher" / source) for source in sources],
            str(harness), "-o", str(binary),
        ], check=True, timeout=120)
        for mode in [
            "success", "rate-seconds", "rate-date", "rate-infinity",
            "rate-overflow", "rate-invalid-date", "expired", "network-failure",
            "persist-write", "persist-read",
        ]:
            subprocess.run([str(binary)], check=True, timeout=15,
                           env={**os.environ, "USAGE_CHECK_CASE": mode})


if __name__ == "__main__":
    main()
