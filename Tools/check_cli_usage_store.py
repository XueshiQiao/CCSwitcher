#!/usr/bin/env python3
"""Offline: detect cross-account cache imports, lost Fable data and fabricated freshness."""
from pathlib import Path
import subprocess
import tempfile

HARNESS = r'''
import Foundation
enum L10n { static let bundle = Bundle.main }
@main struct Check {
    static func main() throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("claude.json")
        let id = UUID().uuidString
        let email = "fixture@example.invalid"
        let now = Date().timeIntervalSince1970
        let reset = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now + 3600))
        let identity: [String: Any] = ["accountUuid": id, "emailAddress": email]
        let fable: [String: Any] = ["kind": "weekly_scoped", "percent": 67,
            "resets_at": NSNull(), "scope": ["model": ["display_name": "Fable", "id": NSNull()]], "is_active": false]
        let usage: [String: Any] = ["five_hour": ["utilization": 82, "resets_at": reset], "limits": [fable]]
        let original: [String: Any] = ["accountUuid": id, "fetchedAtMs": (now - 90) * 1000, "utilization": usage]
        func read(_ cache: [String: Any]?, oauth: [String: Any]? = nil) throws -> CLIUsageStore.Snapshot? {
            var config: [String: Any] = ["oauthAccount": oauth ?? identity]
            if let cache { config["cachedUsageUtilization"] = cache }
            try JSONSerialization.data(withJSONObject: config).write(to: path, options: .atomic)
            return try CLIUsageStore.read(accountUuid: id.lowercased(), email: email, configurationURL: path)
        }
        func reject(_ cache: [String: Any], oauth: [String: Any]? = nil) throws {
            do { _ = try read(cache, oauth: oauth) } catch { return }
            fatalError("Accepted an untrusted or cross-account record")
        }
        let missing = try read(nil)
        precondition(missing == nil)
        let snapshot = try read(original)!
        precondition(snapshot.usage.fiveHour?.utilization == 82)
        precondition(snapshot.usage.sevenDay == nil && snapshot.usage.sevenDayFable?.utilization == 67)
        precondition(snapshot.usage.sevenDayFable?.resetsAt == nil)
        precondition(abs(snapshot.observedAt - (now - 90)) < 0.001, "Import fabricated freshness")
        let persisted = try JSONDecoder().decode(UsageAPIResponse.self, from: JSONEncoder().encode(snapshot.usage))
        precondition(persisted.sevenDayFable?.utilization == 67, "Persistence discarded Fable")
        let reread = try read(original)!
        precondition(reread.observedAt == snapshot.observedAt)

        var changed = original
        changed["accountUuid"] = UUID().uuidString; try reject(changed)
        changed.removeValue(forKey: "accountUuid"); try reject(changed)
        try reject(original, oauth: ["accountUuid": UUID().uuidString, "emailAddress": email])
        try reject(original, oauth: ["accountUuid": id, "emailAddress": "another@example.invalid"])
        changed = original; changed["fetchedAtMs"] = (now + 3600) * 1000; try reject(changed)
        changed["fetchedAtMs"] = 0; try reject(changed)
        changed = original
        changed["utilization"] = ["five_hour": ["utilization": 101, "resets_at": reset]]; try reject(changed)
        changed["utilization"] = ["five_hour": ["utilization": 50, "resets_at": "not-a-date"]]; try reject(changed)
        var invalidFable = fable
        invalidFable["percent"] = -1
        changed["utilization"] = ["limits": [invalidFable]]; try reject(changed)
        changed["utilization"] = ["limits": [fable, fable]]; try reject(changed)

        for limits in [NSNull(), [] as [[String: Any]], [["kind": "weekly_all", "percent": 40, "scope": ["model": ["display_name": "Fable"]]]],
                       [["kind": "weekly_scoped", "percent": 40, "scope": ["model": ["display_name": "Sonnet"]]]]] as [Any] {
            changed["utilization"] = ["five_hour": ["utilization": 10], "limits": limits,
                                      "iguana_necktie": ["utilization": 88]]
            let absent = try read(changed)!
            precondition(absent.usage.sevenDayFable == nil, "Invented Fable from another limit")
        }
        changed["utilization"] = ["limits": [fable]]
        let fableOnly = try read(changed)!
        precondition(fableOnly.usage.fiveHour == nil && fableOnly.usage.sevenDayFable?.utilization == 67)
        changed["utilization"] = ["five_hour": ["utilization": 100, "resets_at": "2000-01-01T00:00:00Z"]]
        let expired = try read(changed)!
        precondition(expired.usage.fiveHour?.utilization == 100, "Elapsed window fabricated unused quota")
        print("PASS: official cache identity, Fable parsing/persistence, missing windows, honest timestamps and invalid data rejection")
    }
}
'''


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="cli-usage-store-") as temporary:
        work = Path(temporary)
        harness = work / "Check.swift"
        harness.write_text(HARNESS)
        binary = work / "check"
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(work / "modules"),
                        str(root / "CCSwitcher/Models/UsageData.swift"), str(root / "CCSwitcher/Services/CLIUsageStore.swift"),
                        str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(work)], check=True)

if __name__ == "__main__":
    main()
