#!/usr/bin/env python3
"""Offline account authorization check: uv run python3 Tools/check_stored_authorization.py.

Compiles the real editor against an in-memory keychain boundary and the real legacy
reader against fake system calls. Wrong-account reads, live fallbacks, hidden store
failures, or modifying legacy credentials during inspection fail this check.
"""

from pathlib import Path
import subprocess
import tempfile


HARNESS = r'''
import SwiftUI

struct Account: Identifiable {
    let id: UUID
    var customLabel: String?
    let email = "fixture@example.invalid"
    func displayEmail(obfuscated: Bool) -> String { "fixture@example.invalid" }
}
@MainActor final class AppState: ObservableObject {
    func updateAccountLabel(_ account: Account, label: String?) {}
}
struct AccountBackup: Codable {
    let token: String
    let oauthAccount: [String: String]
}
final class KeychainService: Sendable {
    static let shared = KeychainService()
    enum BackupLookup { case found(AccountBackup), missing, storeUnavailable }
    func lookupAccountBackup(forAccountId id: String, migrateLegacyStore: Bool = true) -> BackupLookup {
        precondition(!migrateLegacyStore, "Inspecting authorization must not migrate or modify its store")
        switch id {
        case "00000000-0000-0000-0000-000000000001":
            return .found(AccountBackup(token: "{\"accessToken\":\"fixture-a\"}",
                                        oauthAccount: ["emailAddress": "a@example.invalid"]))
        case "00000000-0000-0000-0000-000000000002":
            return .found(AccountBackup(token: "fixture-b", oauthAccount: ["emailAddress": "b@example.invalid"]))
        case "00000000-0000-0000-0000-000000000003": return .missing
        case "00000000-0000-0000-0000-000000000004": return .storeUnavailable
        default: fatalError("Unexpected account ID")
        }
    }
    func readClaudeToken() -> String? { fatalError("Must not read live credentials") }
    func readOAuthAccount() -> [String: String]? { fatalError("Must not read live identity") }
}

@main struct Check {
    static func main() throws {
        for suffix in [1, 2] {
            let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(suffix)")!
            guard case .json(let json) = StoredAuthorization.load(accountID: id) else {
                fatalError("Stored account should be inspectable")
            }
            let decoded = try JSONDecoder().decode(AccountBackup.self, from: Data(json.utf8))
            let expected = suffix == 1 ? "{\"accessToken\":\"fixture-a\"}" : "fixture-b"
            precondition(decoded.token == expected, "Authorization must preserve the selected account's token")
            precondition(decoded.oauthAccount["emailAddress"] == (suffix == 1 ? "a@example.invalid" : "b@example.invalid"))
        }
        guard case .missing = StoredAuthorization.load(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!) else {
            fatalError("Missing backup must not fall back to another account")
        }
        guard case .unavailable = StoredAuthorization.load(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!) else {
            fatalError("Unavailable store must not be presented as missing")
        }
        print("PASS: selected-account authorization, exact JSON values, missing/unavailable, no live fallback")
    }
}
'''


LEGACY_HARNESS = r'''
import Foundation
import Security

struct FileLog: Sendable {
    init(_ category: String) {}
    func info(_ message: String) {}
    func error(_ message: String) {}
    func debug(_ message: String) {}
}

nonisolated(unsafe) var keychainReads = 0
func NSHomeDirectory() -> String { CommandLine.arguments[1] }
func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    keychainReads += 1
    return errSecItemNotFound
}
func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    fatalError("Authorization inspection must not write to the keychain")
}
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    fatalError("Authorization inspection must not update the keychain")
}
func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    fatalError("Authorization inspection must not delete keychain items")
}

@main struct CheckLegacy {
    static func main() throws {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ccswitcher")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("backups.json")
        let id = "00000000-0000-0000-0000-000000000001"
        let backup = AccountBackup(token: "fixture-token", oauthAccount: ["emailAddress": AnyCodable("fixture@example.invalid")])
        let validBytes = try JSONEncoder().encode([id: backup])
        try validBytes.write(to: file)
        let service = KeychainService.shared

        for bytes in [validBytes, Data("{broken-json".utf8)] {
            try bytes.write(to: file)
            let beforeNames = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
            let beforeFileTime = try fileManager.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            let beforeDirectoryTime = try fileManager.attributesOfItem(atPath: directory.path)[.modificationDate] as! Date
            let result = service.lookupAccountBackup(forAccountId: id, migrateLegacyStore: false)
            if bytes == validBytes {
                guard case .found(let stored) = result else { fatalError("Valid legacy backup must load") }
                precondition(stored.token == backup.token)
                precondition(stored.oauthAccount == backup.oauthAccount)
            } else {
                guard case .storeUnavailable = result else { fatalError("Corrupt legacy store must remain unavailable") }
            }
            let afterBytes = try Data(contentsOf: file)
            let afterNames = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
            let afterFileTime = try fileManager.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            let afterDirectoryTime = try fileManager.attributesOfItem(atPath: directory.path)[.modificationDate] as! Date
            precondition(afterBytes == bytes, "Inspection must preserve the exact file bytes")
            precondition(afterNames == beforeNames,
                         "Inspection must not rename, remove, or create credential files")
            precondition(afterFileTime == beforeFileTime)
            precondition(afterDirectoryTime == beforeDirectoryTime)
        }
        precondition(keychainReads == 2, "Every read must use the fake keychain boundary")
        print("PASS: real legacy backup reader preserves valid/corrupt files and never writes credentials")
    }
}
'''


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="ccswitcher-stored-auth-") as directory:
        temporary = Path(directory)
        harness = temporary / "check.swift"
        harness.write_text(HARNESS)
        executable = temporary / "check"
        subprocess.run([
            "swiftc", "-swift-version", "6", "-module-cache-path", str(temporary / "module-cache"),
            str(root / "CCSwitcher/Views/AccountEditView.swift"),
            str(root / "CCSwitcher/Views/Components/CopyEmailButton.swift"), str(harness), "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True)

        legacy_harness = temporary / "legacy.swift"
        legacy_harness.write_text(LEGACY_HARNESS)
        legacy_executable = temporary / "legacy"
        subprocess.run([
            "swiftc", "-swift-version", "6", "-module-cache-path", str(temporary / "module-cache"),
            str(root / "CCSwitcher/Services/KeychainService.swift"), str(legacy_harness),
            "-o", str(legacy_executable),
        ], check=True)
        # Prove the imported system boundaries were shadowed before running anything.
        undefined_symbols = subprocess.run(
            ["nm", "-u", str(legacy_executable)], check=True, capture_output=True, text=True
        ).stdout
        for symbol in ["SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete", "NSHomeDirectory"]:
            if symbol in undefined_symbols:
                raise RuntimeError(f"Refusing to run: real system boundary {symbol} is still linked")
        fixture_home = temporary / "fixture-home"
        fixture_home.mkdir()
        subprocess.run([str(legacy_executable), str(fixture_home)], check=True)


if __name__ == "__main__":
    main()
