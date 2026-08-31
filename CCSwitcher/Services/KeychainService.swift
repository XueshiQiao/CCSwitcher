import Foundation
import Security

private let log = FileLog("Keychain")

/// Per-account backup: keychain token + oauthAccount from ~/.claude.json
struct AccountBackup: Codable {
    let token: String
    let oauthAccount: [String: AnyCodable]

    /// Whether the stored token still carries an OAuth secret the CLI could
    /// authenticate with.
    ///
    /// A capture that runs while the CLI holds no live login writes back a
    /// full-looking envelope with `accessToken` and `refreshToken` both set to
    /// the empty string. Nothing else about that backup looks wrong: the
    /// `oauthAccount` block is intact, the email is right, the scopes and
    /// `subscriptionType` are right, and the JSON is only a couple of hundred
    /// bytes shorter than a good one. So it survives every existing check,
    /// gets written over a working login, and fails verification a moment
    /// later.
    ///
    /// An envelope with no `claudeAiOauth` block at all is left alone: that is
    /// an auth shape this check does not know about, and refusing it would
    /// block switches that work today.
    var hasUsableCredentials: Bool {
        guard let data = token.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { return true }
        let accessToken = oauth["accessToken"] as? String ?? ""
        let refreshToken = oauth["refreshToken"] as? String ?? ""
        return !accessToken.isEmpty || !refreshToken.isEmpty
    }
}

/// Type-erased Codable wrapper for heterogeneous JSON values.
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a }
        else if let o = try? container.decode([String: AnyCodable].self) { value = o }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [AnyCodable]: try container.encode(a)
        case let o as [String: AnyCodable]: try container.encode(o)
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

/// Manages token + identity storage:
/// - Claude CLI's token: read/write via `security` CLI (keychain).
/// - Claude CLI's identity: read/write oauthAccount in ~/.claude.json.
/// - Our backups: per-account {token, oauthAccount} in ~/.ccswitcher/backups.json.
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let claudeService = "Claude Code-credentials"
    private let claudeAccount: String
    private let backupsFilePath: String
    private let claudeJsonPath: String

    /// Serializes every access to the backup store. All backups live in ONE
    /// keychain item, so each mutation is load-whole-store -> mutate -> save-
    /// whole-store; two of those interleaving (AppState runs on the main actor,
    /// but `ClaudeService.switchAccount` runs off it) can silently drop another
    /// account's freshly written credentials.
    private let storeLock = NSLock()

    private init() {
        self.claudeAccount = NSUserName()

        let home = NSHomeDirectory()
        let dir = home + "/.ccswitcher"
        self.backupsFilePath = dir + "/backups.json"
        self.claudeJsonPath = home + "/.claude.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Migrate old tokens.json → backups.json if needed
        let oldPath = dir + "/tokens.json"
        if FileManager.default.fileExists(atPath: oldPath) && !FileManager.default.fileExists(atPath: backupsFilePath) {
            log.info("init: Migrating tokens.json → backups.json (old format, token-only entries)")
            // Old format was {accountId: tokenString}. We can't migrate without oauthAccount,
            // so just delete the stale file — user will need to re-capture.
            try? FileManager.default.removeItem(atPath: oldPath)
        }

        log.info("init: claudeAccount=\(claudeAccount), backupsFile=\(backupsFilePath)")
    }

    // MARK: - Claude Code Token Operations (keychain via `security` CLI)

    func readClaudeToken() -> String? {
        let token = runSecurity(args: [
            "find-generic-password",
            "-s", claudeService,
            "-a", claudeAccount,
            "-w"
        ])
        
        if let token {
            // Clean up possible trailing newlines from security CLI output
            let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("[readClaudeToken] Found via security CLI, length=\(sanitized.count)")
            return sanitized
        } else {
            log.error("[readClaudeToken] No token found!")
            return nil
        }
    }

    func writeClaudeToken(_ token: String) -> Bool {
        // Delete then add (security CLI doesn't have a pure "update" for generic passwords)
        _ = runSecurityStatus(args: ["delete-generic-password", "-s", claudeService, "-a", claudeAccount])

        let added = runSecurityStatus(args: [
            "add-generic-password",
            "-s", claudeService,
            "-a", claudeAccount,
            "-w", token,
            "-U"
        ])
        log.info("[writeClaudeToken] Result: \(added)")
        return added
    }

    // MARK: - ~/.claude.json oauthAccount Operations

    func readOAuthAccount() -> [String: AnyCodable]? {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              let json = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              let oauthEntry = json["oauthAccount"],
              let dict = oauthEntry.value as? [String: AnyCodable] else {
            log.error("[readOAuthAccount] Failed to read oauthAccount from \(claudeJsonPath)")
            return nil
        }
        let email = (dict["emailAddress"]?.value as? String) ?? "?"
        log.info("[readOAuthAccount] Found: email=\(email)")
        return dict
    }

    func writeOAuthAccount(_ oauthAccount: [String: AnyCodable]) -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              var json = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            log.error("[writeOAuthAccount] Failed to read \(claudeJsonPath)")
            return false
        }

        json["oauthAccount"] = AnyCodable(oauthAccount)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let newData = try encoder.encode(json)
            try newData.write(to: URL(fileURLWithPath: claudeJsonPath), options: .atomic)
            let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[writeOAuthAccount] Written: email=\(email)")
            return true
        } catch {
            log.error("[writeOAuthAccount] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Account Backup Operations (token + oauthAccount)

    func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId accountId: String) -> Bool {
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[saveBackup] Saving for \(accountId) (\(email)), token length=\(token.count)")
        storeLock.lock()
        defer { storeLock.unlock() }
        var store: [String: AccountBackup]
        switch loadBackupStore() {
        case .loaded(let dict): store = dict
        case .empty: store = [:]
        case .failed(let reason):
            // Writing a mutated copy back after a failed load would replace
            // EVERY account's credentials with just this one entry. Refuse.
            log.error("[saveBackup] REFUSED: store unreadable (\(reason)); writing now would destroy the other accounts' backups")
            return false
        }
        store[accountId] = AccountBackup(token: token, oauthAccount: oauthAccount)
        let result = saveBackupStore(store)
        log.info("[saveBackup] Result: \(result)")
        return result
    }

    /// Result of looking up one account's backup. "The entry does not exist"
    /// and "the store could not be read right now" are different answers with
    /// different remedies (re-authenticate vs simply try again later), so the
    /// distinction is kept at the public boundary instead of collapsing both
    /// into nil.
    enum BackupLookup {
        case found(AccountBackup)
        case missing
        case storeUnavailable
    }

    func lookupAccountBackup(forAccountId accountId: String) -> BackupLookup {
        storeLock.lock()
        defer { storeLock.unlock() }
        switch loadBackupStore() {
        case .loaded(let store):
            guard let backup = store[accountId] else {
                log.error("[getBackup] No backup for accountId=\(accountId)")
                return .missing
            }
            // Account id only — no email in logs (HARD RULE 6); the id is a
            // locally-minted UUID that correlates log lines without
            // identifying anyone.
            log.info("[getBackup] Found for \(accountId), credential length=\(backup.token.count)")
            return .found(backup)
        case .empty:
            log.error("[getBackup] No backup for accountId=\(accountId) (store is empty)")
            return .missing
        case .failed(let reason):
            log.error("[getBackup] Store unreadable (\(reason)); \(accountId) unavailable until it recovers")
            return .storeUnavailable
        }
    }

    /// Convenience for call sites where "missing" and "unavailable" demand the
    /// same behavior (skip / treat as not switchable). Paths that tell the user
    /// what to DO about it must use `lookupAccountBackup` instead.
    func getAccountBackup(forAccountId accountId: String) -> AccountBackup? {
        if case .found(let backup) = lookupAccountBackup(forAccountId: accountId) {
            return backup
        }
        return nil
    }

    @discardableResult
    func removeAccountBackup(forAccountId accountId: String) -> Bool {
        log.info("[removeBackup] Removing for accountId=\(accountId)")
        storeLock.lock()
        defer { storeLock.unlock() }
        var store: [String: AccountBackup]
        switch loadBackupStore() {
        case .loaded(let dict): store = dict
        case .empty: return true
        case .failed(let reason):
            log.error("[removeBackup] REFUSED: store unreadable (\(reason)); writing now would destroy the other accounts' backups")
            return false
        }
        store.removeValue(forKey: accountId)
        return saveBackupStore(store)
    }

    // Legacy compatibility — read token string only (for diagnostics)
    func getAccountToken(forAccountId accountId: String) -> String? {
        return getAccountBackup(forAccountId: accountId)?.token
    }

    // MARK: - App Keychain operations (Backups)

    private let appBackupService = "me.xueshi.ccswitcher.backups"
    private let appBackupAccount = "all-accounts"

    /// Result of reading the single keychain item that holds every backup.
    /// The `empty`/`failed` distinction is load-bearing: `empty` means the item
    /// genuinely does not exist yet, while `failed` means it MAY exist but could
    /// not be read (denied prompt, locked keychain) or decoded. Mutating "what we
    /// loaded" after a failed load and saving it back would truncate the store to
    /// the single entry being saved, destroying every other account's credentials.
    private enum BackupStoreLoad {
        case loaded([String: AccountBackup])
        case empty
        case failed(String)
    }

    /// Must be called with `storeLock` held.
    private func loadBackupStore() -> BackupStoreLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appBackupService,
            kSecAttrAccount as String: appBackupAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return .failed("keychain returned no data")
            }
            guard let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) else {
                // Data exists but we can't parse it. It is NOT gone — refuse to
                // treat it as empty so nothing ever writes over it.
                log.error("[loadBackupStore] Item exists (\(data.count) bytes) but did not decode")
                return .failed("undecodable store data")
            }
            log.debug("[loadBackupStore] Loaded \(dict.count) entries from Keychain")
            return .loaded(dict)

        case errSecItemNotFound:
            // Migration from local file (pre-keychain versions)
            if FileManager.default.fileExists(atPath: backupsFilePath) {
                guard let data = FileManager.default.contents(atPath: backupsFilePath),
                      let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) else {
                    // The legacy file EXISTS but can't be read or parsed. It may
                    // hold every credential the user has; falling through to
                    // `.empty` here would let the next save create a keychain
                    // item, after which this file is never consulted again —
                    // permanently stranding its contents. Preserve it under a
                    // timestamped name (recoverable by hand) and only then treat
                    // the store as empty; if even that fails, refuse writes.
                    let aside = backupsFilePath + ".unreadable-\(Int(Date().timeIntervalSince1970))"
                    do {
                        try FileManager.default.moveItem(atPath: backupsFilePath, toPath: aside)
                        log.error("[loadBackupStore] Legacy backups.json unreadable; preserved at \(aside)")
                        return .empty
                    } catch {
                        log.error("[loadBackupStore] Legacy backups.json unreadable and could not be preserved: \(error.localizedDescription)")
                        return .failed("legacy backups.json unreadable")
                    }
                }
                log.info("[loadBackupStore] Migrating from local backups.json to Keychain...")
                guard saveBackupStore(dict) else {
                    // Do not delete the file until the keychain copy is real.
                    log.error("[loadBackupStore] Migration save failed; keeping backups.json")
                    return .failed("migration save failed")
                }
                try? FileManager.default.removeItem(atPath: backupsFilePath)
                log.info("[loadBackupStore] Migration complete, local backups.json removed")
                return .loaded(dict)
            }
            log.debug("[loadBackupStore] No existing backups")
            return .empty

        default:
            // Read failure (e.g. user denied the keychain prompt, keychain
            // locked). The item's contents are unknown — not absent.
            log.error("[loadBackupStore] Read failed, OSStatus: \(status)")
            return .failed("OSStatus \(status)")
        }
    }

    /// Must be called with `storeLock` held.
    private func saveBackupStore(_ store: [String: AccountBackup]) -> Bool {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(store)
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: appBackupService,
                kSecAttrAccount as String: appBackupAccount
            ]
            
            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]
            
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            
            if status == errSecItemNotFound {
                var newItem = query
                newItem[kSecValueData as String] = data
                status = SecItemAdd(newItem as CFDictionary, nil)
            }
            
            let success = status == errSecSuccess
            if success {
                log.debug("[saveBackupStore] Saved \(store.count) entries to Keychain")
            } else {
                log.error("[saveBackupStore] Failed to save to Keychain, OSStatus: \(status)")
            }
            return success
        } catch {
            log.error("[saveBackupStore] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - `security` CLI (only for Claude's keychain entry)

    private func runSecurity(args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                log.debug("[runSecurity] Exit \(process.terminationStatus) for: security \(args.prefix(3).joined(separator: " "))...")
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            log.error("[runSecurity] Launch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func runSecurityStatus(args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            if !ok {
                log.debug("[runSecurityStatus] Exit \(process.terminationStatus) for: security \(args.prefix(3).joined(separator: " "))...")
            }
            return ok
        } catch {
            log.error("[runSecurityStatus] Launch failed: \(error.localizedDescription)")
            return false
        }
    }
}
