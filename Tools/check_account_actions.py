#!/usr/bin/env python3
"""Offline AppState regression check: uv run python3 Tools/check_account_actions.py.

Real AppState and models run against in-memory CLI, credential, filesystem and
widget boundaries. Reintroducing background CLI calls, token reads for quota,
cross-account quota imports, post-cancel capture, lost local sample timestamps,
or destructive recycling fails.
"""

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
enum L10n { static let bundle = Bundle.main }
struct AnyCodable { let value: String; init(_ value: String) { self.value = value } }
struct AccountBackup { let token: String; let oauthAccount: [String: AnyCodable] }

@MainActor final class KeychainService {
    static let shared = KeychainService()
    var email = "unknown@example.invalid"
    var accountUuid: String?
    var backups: [String: AccountBackup] = [:]
    func readOAuthAccount() -> [String: AnyCodable]? {
        var identity = ["emailAddress": AnyCodable(email)]
        if let accountUuid { identity["accountUuid"] = AnyCodable(accountUuid) }
        return identity
    }
    func activate(_ account: Account, serverID: String? = nil) {
        email = account.email
        accountUuid = serverID ?? account.id.uuidString
    }
    var backupReads = 0
    var tokenReads = 0
    func readClaudeToken() -> String? { tokenReads += 1; return "active-fixture" }
    func getAccountBackup(forAccountId id: String) -> AccountBackup? { backupReads += 1; return backups[id] }
    func removeAccountBackup(forAccountId id: String) { backups[id] = nil }
    enum Lookup { case found(AccountBackup), missing, storeUnavailable }
    func lookupAccountBackup(forAccountId id: String) -> Lookup {
        backupReads += 1
        return backups[id].map { .found($0) } ?? .missing
    }
}

@MainActor final class ClaudeService {
    static let shared = ClaudeService()
    var captured: [String] = []
    let claudePath = "/usr/bin/true"
    var versionCalls = 0
    var authCalls = 0
    var loginCalls = 0
    var completesLogin = false
    var switched: [(UUID?, UUID)] = []
    func isClaudeAvailable() async -> Bool { versionCalls += 1; return true }
    func getAuthStatus() async throws -> AuthStatus {
        authCalls += 1
        return AuthStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: nil,
                          email: KeychainService.shared.email, orgId: nil, orgName: nil, subscriptionType: nil)
    }
    func login(onURL: @escaping @Sendable (URL) async -> Void) async throws {
        loginCalls += 1
        await onURL(URL(string: "https://claude.ai/oauth/authorize?state=offline")!)
        if !completesLogin { try await Task.sleep(for: .seconds(30)) }
    }
    func captureCurrentCredentials(forAccountId id: String) -> Bool { captured.append(id); return true }
    struct SwitchOutcome { let shadowedBy: String? }
    func switchAccount(from source: Account?, to target: Account, targetBackup: AccountBackup) async throws -> SwitchOutcome {
        switched.append((source?.id, target.id))
        KeychainService.shared.email = target.email
        return SwitchOutcome(shadowedBy: nil)
    }
}

@MainActor enum CLIUsageSession {
    static var opened: [String] = []
    static var failure: Error?
    static func open(claudePath: String, accountUuid: String, email: String) throws {
        if let failure { throw failure }
        opened.append(accountUuid)
    }
}

@MainActor enum CLIUsageStore {
    struct Snapshot {
        let accountUuid: String
        let email: String
        let observedAt: Double
        let usage: UsageAPIResponse
    }
    static var snapshots: [String: Snapshot] = [:]
    static var reads: [String] = []
    static var readError: Error?
    static func read(accountUuid: String, email: String) throws -> Snapshot? {
        reads.append(accountUuid)
        if let readError { throw readError }
        guard let snapshot = snapshots[accountUuid] else { return nil }
        guard snapshot.accountUuid == accountUuid && snapshot.email == email else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }
    static func install(_ account: Account, observedAt: Double = floor(Date().timeIntervalSince1970) - 120,
                        used: Double = 23, serverID: String? = nil, resetsAt: String = "2100-01-01T00:00:00Z") {
        let accountUuid = serverID ?? account.id.uuidString
        KeychainService.shared.backups[account.id.uuidString] = AccountBackup(token: "unused-fixture", oauthAccount: [
            "accountUuid": AnyCodable(accountUuid), "emailAddress": AnyCodable(account.email)
        ])
        let usage = try! JSONDecoder().decode(UsageAPIResponse.self,
            from: Data("{\"five_hour\":{\"utilization\":\(used),\"resets_at\":\"\(resetsAt)\"},\"seven_day\":{\"utilization\":42,\"resets_at\":\"\(resetsAt)\"},\"seven_day_fable\":{\"utilization\":67,\"resets_at\":\"\(resetsAt)\"}}".utf8))
        snapshots[accountUuid] = Snapshot(accountUuid: accountUuid, email: account.email, observedAt: observedAt, usage: usage)
    }
}

@MainActor struct StatsParser {
    static let shared = StatsParser()
    func getUsageSummary() -> UsageSummary { .empty }
    func getRecentActivity(days: Int) -> [DailyActivity] { [] }
    func getActiveSessions() -> [SessionInfo] { [] }
}
@MainActor struct CostParser {
    static let shared = CostParser()
    func getCostSummary() async -> CostSummary { .empty }
}
@MainActor struct ActivityParser {
    static let shared = ActivityParser()
    func getTodayStats() async -> ActivityStats { .empty }
}
@MainActor struct SessionParseCacheV2 {
    static let shared = SessionParseCacheV2()
    func refreshFromFilesystem() async {}
}
struct WidgetAccountData {
    let email: String; let displayName: String; let subscriptionType: String?; let isActive: Bool
    let sessionUtilization: Double?; let sessionResetTime: String?
    let weeklyUtilization: Double?; let weeklyResetTime: String?
    let extraUsageEnabled: Bool?; let hasError: Bool; let errorMessage: String?
}
struct WidgetData {
    let accounts: [WidgetAccountData]; let todayCost: Double; let conversationTurns: Int
    let activeCodingTime: String; let linesWritten: Int; let modelUsage: [String: Int]; let lastUpdated: Date
    @MainActor static var lastSavedEmails: [String] = []
    @MainActor func save() { Self.lastSavedEmails = accounts.map(\.email) }
}
struct WidgetCenter: Sendable {
    static let shared = WidgetCenter()
    func reloadAllTimelines() {}
}

@main struct AccountCheck {
    @MainActor static func checkExplicitCLISession() async throws {
        let state = AppState()
        let a = Account(email: "a@example.invalid", displayName: "A")
        let b = Account(email: "b@example.invalid", displayName: "B")
        state.accounts = [a, b]
        state.activeAccount = a
        KeychainService.shared.activate(a)
        CLIUsageSession.opened = []
        state.openCLIUsageSession(b)
        precondition(CLIUsageSession.opened.isEmpty)
        state.isSwitching = true
        state.openCLIUsageSession(a)
        precondition(CLIUsageSession.opened.isEmpty)
        state.isSwitching = false
        CLIUsageSession.failure = CocoaError(.fileWriteUnknown)
        state.openCLIUsageSession(a)
        precondition(state.cliUsageCheckAvailableAt(a) == nil)
        CLIUsageSession.failure = nil
        let samples = state.accountUsageSampledAt
        state.openCLIUsageSession(a)
        precondition(state.errorMessage == nil)
        state.openCLIUsageSession(a)
        precondition(CLIUsageSession.opened == [a.id.uuidString])
        precondition(state.accountUsageSampledAt == samples)
        precondition(state.cliUsageCheckAvailableAt(a) != nil && state.cliUsageCheckAvailableAt(b) == nil)
        precondition(AppState().cliUsageCheckAvailableAt(a) != nil)
        CLIUsageStore.install(a)
        await state.refreshAccountUsage(a)
        precondition(state.accountUsage[a.id] != nil, "CLI launch cooldown blocked a local cache read")
        state.activeAccount = b
        KeychainService.shared.activate(b)
        state.openCLIUsageSession(b)
        precondition(CLIUsageSession.opened == [a.id.uuidString, b.id.uuidString])
        for account in [a, b] { UserDefaults.standard.removeObject(forKey: "cliUsageCheckStarted." + account.id.uuidString) }
    }

    @MainActor static func checkManualSwitchOnly() async throws {
        let defaults = UserDefaults.standard
        defaults.setVolatileDomain(["autoSwitchEnabled": true], forName: UserDefaults.argumentDomain)
        let service = ClaudeService.shared
        for recycleActive in [true, false] {
            let state = AppState()
            let active = Account(email: "active@example.invalid", displayName: "Active", isActive: true)
            let candidate = Account(email: "candidate@example.invalid", displayName: "Candidate")
            state.accounts = [active, candidate]
            state.activeAccount = active
            state.automaticUsageAccountIDs = Set([active.id.uuidString, candidate.id.uuidString])
            state.lastAutoSwitchAt = nil
            KeychainService.shared.email = active.email
            KeychainService.shared.backups[candidate.id.uuidString] = AccountBackup(token: "candidate-fixture", oauthAccount: [:])
            for (account, utilization) in [(active, 95), (candidate, 10)] {
                state.accountUsage[account.id] = try JSONDecoder().decode(UsageAPIResponse.self,
                    from: Data("{\"five_hour\":{\"utilization\":\(utilization),\"resets_at\":\"2099-01-01T00:00:00Z\"}}".utf8))
                state.accountUsageSampledAt[account.id] = Date()
                CLIUsageStore.install(account, used: Double(utilization))
            }
            service.switched = []
            service.authCalls = 0
            service.versionCalls = 0
            service.loginCalls = 0
            service.captured = []
            await state.refresh()
            precondition(service.switched.isEmpty, "Historical network readings triggered automatic switching")
            state.cliUsageAccountIDs = [active.id, candidate.id]
            let recycled = recycleActive ? active : candidate
            state.recycleAccount(recycled)
            service.switched = []
            CLIUsageStore.reads = []
            await state.refresh()
            precondition(service.switched.isEmpty,
                         "Auto-switch used a recycled source or candidate")
            precondition(state.activeAccount?.id == active.id)
            state.restoreAccount(recycled)
            await state.refresh()
            precondition(service.switched.isEmpty && state.activeAccount?.id == active.id,
                         "Fresh local samples and legacy preferences triggered a background switch")
            precondition(service.authCalls == 0 && service.versionCalls == 0 && service.loginCalls == 0 && service.captured.isEmpty,
                         "Background refresh invoked CLI or captured credentials")
            await state.switchTo(candidate)
            precondition(service.switched.count == 1 && service.switched[0].1 == candidate.id,
                         "Disabling background switching blocked an explicit account switch")
            precondition(state.activeAccount?.id == candidate.id)
        }
        print("PASS: background refresh never switches accounts or starts CLI despite legacy settings; explicit switching works")
    }

    @MainActor static func checkLocalUsage(_ known: Account) async throws {
        let state = AppState()
        let service = ClaudeService.shared
        let credentials = KeychainService.shared
        let target = Account(email: "target@example.invalid", displayName: "Target")
        let serverID = UUID().uuidString
        let observed = floor(Date().timeIntervalSince1970) - 120
        state.accounts = [known, target]
        state.activeAccount = known
        state.automaticUsageAccountIDs = []
        credentials.activate(known)
        CLIUsageStore.install(target, observedAt: observed, serverID: serverID)
        CLIUsageStore.reads = []
        service.authCalls = 0
        service.versionCalls = 0
        service.loginCalls = 0
        service.captured = []
        service.switched = []
        credentials.tokenReads = 0
        credentials.backupReads = 0
        await state.refreshAccountUsage(target)
        precondition(CLIUsageStore.reads.isEmpty && state.accountUsage[target.id] == nil,
                     "An inactive account reached the quota reader")

        // The activity marker alone cannot establish ownership after an external CLI switch.
        state.activeAccount = target
        await state.refreshAccountUsage(target)
        precondition(CLIUsageStore.reads.isEmpty && state.accountUsageErrors[target.id] != nil,
                     "A stale activity marker imported another account's quota")
        credentials.activate(target, serverID: serverID)
        await state.refreshAccountUsage(target)
        precondition(CLIUsageStore.reads == [serverID], "Local import used the UI id instead of the live official identity")
        precondition(state.accountUsage[target.id]?.fiveHour?.utilization == 23)
        precondition(state.accountUsageSampledAt[target.id] == Date(timeIntervalSince1970: observed))
        precondition(state.cliUsageAccountIDs == [target.id] && state.accountUsage[known.id] == nil)
        let cached = UserDefaults.standard.data(forKey: "savedUsage." + target.id.uuidString)!
        for stamp in [observed, observed - 300] {
            CLIUsageStore.install(target, observedAt: stamp, used: 91, serverID: serverID)
            await state.refreshAccountUsage(target)
            precondition(state.accountUsage[target.id]?.fiveHour?.utilization == 23 && state.accountUsageSampledAt[target.id] == Date(timeIntervalSince1970: observed),
                         "Equal or older local cache rewrote a newer reading")
        }
        CLIUsageStore.snapshots[serverID] = nil
        await state.refreshAccountUsage(target)
        precondition(state.accountUsage[target.id]?.fiveHour?.utilization == 23 && state.accountUsageErrors[target.id] == nil)
        CLIUsageStore.readError = CocoaError(.fileReadCorruptFile)
        await state.refreshAccountUsage(target)
        precondition(state.accountUsageErrors[target.id] != nil)
        CLIUsageStore.readError = nil
        precondition(UserDefaults.standard.data(forKey: "savedUsage." + target.id.uuidString) == cached)
        precondition(state.accountUsageSampledAt[target.id] == Date(timeIntervalSince1970: observed))

        let before = CLIUsageStore.reads.count
        credentials.activate(known)
        state.automaticUsageAccountIDs = [target.id.uuidString]
        await state.refreshAccountUsage(target)
        state.refreshLocalUsage()
        precondition(CLIUsageStore.reads.count == before && state.accountUsageErrors[target.id] != nil,
                     "A changed live identity reached the cache reader")
        precondition(UserDefaults.standard.data(forKey: "savedUsage." + target.id.uuidString) == cached,
                     "Identity mismatch changed the persisted history")
        credentials.activate(target, serverID: serverID)
        credentials.accountUuid = nil
        await state.refreshAccountUsage(target)
        precondition(CLIUsageStore.reads.count == before && state.accountUsageErrors[target.id] != nil,
                     "Missing official identity reached the cache reader")
        credentials.activate(target, serverID: serverID)
        CLIUsageStore.install(target, observedAt: observed + 1, used: 27, serverID: serverID,
                              resetsAt: "2000-01-01T00:00:00Z")
        await state.refreshAccountUsage(target)
        precondition(state.accountUsage[target.id]?.fiveHour?.utilization == 27,
                     "An elapsed reset window invented zero utilization")
        precondition(state.accountUsageSampledAt[target.id] == Date(timeIntervalSince1970: observed + 1))
        precondition(state.accountUsageErrors[target.id] == nil && state.cliUsageAccountIDs == [target.id])
        print("PASS: current-account imports validate live identity and preserve timestamp, provenance and history")

        CLIUsageStore.install(known, observedAt: observed + 2, used: 50)
        CLIUsageStore.install(target, observedAt: observed + 2, used: 33, serverID: serverID)
        state.automaticUsageAccountIDs = [known.id.uuidString]
        precondition(!state.backgroundUsageRefreshEnabled)
        CLIUsageStore.reads = []
        await state.refresh()
        precondition(CLIUsageStore.reads.isEmpty && !state.isLoading && !state.isRefreshing,
                     "An enabled inactive account was automatically imported")
        state.automaticUsageAccountIDs.insert(target.id.uuidString)
        precondition(AppState().automaticUsageAccountIDs == [known.id.uuidString, target.id.uuidString])
        precondition(state.backgroundUsageRefreshEnabled)
        await state.refresh()
        precondition(CLIUsageStore.reads == [serverID] && state.accountUsage[target.id]?.fiveHour?.utilization == 33,
                     "Automatic synchronization did not limit its read to the current account")
        precondition(state.accountUsage[known.id] == nil)

        CLIUsageStore.reads = []
        for busy in 0..<5 {
            state.isLoggingIn = busy == 0
            state.isSwitching = busy == 1
            state.isRefreshing = busy == 2
            state.isLoading = busy == 3
            state.refreshingUsageAccountIDs = busy == 4 ? [target.id] : []
            await state.refreshAccountUsage(target)
            state.refreshLocalUsage()
            precondition(CLIUsageStore.reads.isEmpty, "Quota import ran while account work was in flight")
        }
        state.refreshingUsageAccountIDs = []
        state.automaticUsageAccountIDs = []
        precondition(AppState().automaticUsageAccountIDs.isEmpty)
        await state.refreshAccountUsage(target)
        precondition(CLIUsageStore.reads == [serverID], "Manual current-account import depended on the automatic switch")

        let savedHistory = UserDefaults.standard.data(forKey: "savedUsage." + target.id.uuidString)!
        let savedTime = state.accountUsageSampledAt[target.id]
        state.activeAccount = known
        credentials.activate(known)
        state.automaticUsageAccountIDs = [known.id.uuidString, target.id.uuidString]
        CLIUsageStore.reads = []
        CLIUsageStore.install(target, observedAt: observed + 3, used: 99, serverID: serverID)
        await state.refreshAccountUsage(target)
        state.refreshLocalUsage()
        precondition(CLIUsageStore.reads == [known.id.uuidString])
        precondition(state.accountUsage[target.id]?.fiveHour?.utilization == 33 && state.accountUsageSampledAt[target.id] == savedTime)
        precondition(UserDefaults.standard.data(forKey: "savedUsage." + target.id.uuidString) == savedHistory,
                     "Leaving an account active in preferences changed its historical quota")
        precondition(service.authCalls == 0 && service.versionCalls == 0 && service.loginCalls == 0 && service.captured.isEmpty && service.switched.isEmpty)
        precondition(credentials.tokenReads == 0 && credentials.backupReads == 0,
                     "Local quota imports read credentials or authorization backups")
        print("PASS: only the idle current account can sync; inactive history and per-account preferences persist without CLI/token/backup access")
        // A bridge observation could be newer than the true official cache timestamp.
        // Migration must replace that source once, then enforce official sample ordering.
        let cacheKey = "savedUsage." + target.id.uuidString
        var bridgeRecord = try JSONSerialization.jsonObject(with: savedHistory) as! [String: Any]
        bridgeRecord.removeValue(forKey: "source")
        bridgeRecord["sampledAt"] = Date(timeIntervalSince1970: observed + 600).timeIntervalSinceReferenceDate
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: bridgeRecord), forKey: cacheKey)
        let migrated = AppState()
        migrated.accounts = [target]
        migrated.activeAccount = target
        migrated.loadSavedUsage()
        precondition(migrated.cliUsageAccountIDs.contains(target.id) && !migrated.officialCLIUsageAccountIDs.contains(target.id))
        credentials.activate(target, serverID: serverID)
        CLIUsageStore.install(target, observedAt: observed + 4, used: 11, serverID: serverID)
        await migrated.refreshAccountUsage(target)
        precondition(migrated.accountUsageSampledAt[target.id] == Date(timeIntervalSince1970: observed + 4)
                     && migrated.accountUsage[target.id]?.fiveHour?.utilization == 11,
                     "A bridge observation timestamp blocked the first official quota sample")
        precondition(migrated.accountUsage[target.id]?.sevenDayFable?.utilization == 67)
        let restarted = AppState()
        restarted.accounts = [target]
        restarted.activeAccount = target
        restarted.loadSavedUsage()
        precondition(restarted.officialCLIUsageAccountIDs.contains(target.id), "Official source provenance was not persisted")
        CLIUsageStore.install(target, observedAt: observed + 3, used: 99, serverID: serverID)
        await restarted.refreshAccountUsage(target)
        precondition(restarted.accountUsageSampledAt[target.id] == Date(timeIntervalSince1970: observed + 4)
                     && restarted.accountUsage[target.id]?.fiveHour?.utilization == 11,
                     "Restart allowed an older official sample to replace the saved one")
        print("PASS: migration uses the official sample time once and preserves source ordering after restart")
    }

    @MainActor static func checkSavedUsage(_ mode: String) async throws {
        let defaults = UserDefaults.standard
        let service = ClaudeService.shared
        defaults.setVolatileDomain(["autoSwitchEnabled": false], forName: UserDefaults.argumentDomain)
        if mode == "cache-write" {
            let state = AppState()
            let account = Account(email: "saved@example.invalid", displayName: "Saved", isActive: true)
            state.accounts = [account]
            state.activeAccount = account
            state.saveAccounts()
            CLIUsageStore.install(account)
            KeychainService.shared.activate(account)
            await state.refreshAccountUsage(account)
            precondition(CLIUsageStore.reads == [account.id.uuidString] && state.accountUsage[account.id] != nil)
            defaults.set(try JSONEncoder().encode(state.accountUsageSampledAt[account.id]!), forKey: "expectedSampleTime")
        } else {
            let state = AppState()
            precondition(state.accounts.count == 1)
            let account = state.accounts[0]
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let expected = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(#"{"five_hour":{"utilization":23,"resets_at":"2100-01-01T00:00:00Z"},"seven_day":{"utilization":42,"resets_at":"2100-01-01T00:00:00Z"},"seven_day_fable":{"utilization":67,"resets_at":"2100-01-01T00:00:00Z"}}"#.utf8))
            let actualJSON = try encoder.encode(state.accountUsage[account.id]!)
            let expectedJSON = try encoder.encode(expected)
            precondition(actualJSON == expectedJSON, "Restart lost saved quota fields")
            let persistedWindows = try JSONSerialization.jsonObject(with: actualJSON) as! [String: Any]
            let fable = persistedWindows["seven_day_fable"] as? [String: Any]
            precondition(fable?["utilization"] as? Double == 67 && fable?["resets_at"] as? String == "2100-01-01T00:00:00Z",
                         "Restart lost the Fable percentage or reset time")
            let expectedTime = try JSONDecoder().decode(Date.self, from: defaults.data(forKey: "expectedSampleTime")!)
            precondition(state.accountUsageSampledAt[account.id] == expectedTime, "Restart changed the sample age")
            precondition(CLIUsageStore.reads.isEmpty && state.cliUsageAccountIDs.contains(account.id), "Restoring cached quota lost provenance or read CLI cache")
            if mode == "cache-fail" {
                CLIUsageStore.install(account)
                KeychainService.shared.activate(account)
                CLIUsageStore.readError = CocoaError(.fileReadCorruptFile)
                await state.refreshAccountUsage(account)
                precondition(state.accountUsageErrors[account.id] != nil)
                precondition(state.accountUsageSampledAt[account.id] == expectedTime)
            } else if mode == "cache-read" {
                let cached = defaults.data(forKey: "savedUsage." + account.id.uuidString)!
                KeychainService.shared.backups[account.id.uuidString] = AccountBackup(token: "retained-fixture", oauthAccount: [:])
                state.automaticUsageAccountIDs.insert(account.id.uuidString)
                for busy in 0..<4 {
                    state.isLoggingIn = busy == 0
                    state.isSwitching = busy == 1
                    state.isRefreshing = busy == 2
                    state.refreshingUsageAccountIDs = busy == 3 ? [account.id] : []
                    state.recycleAccount(account)
                    precondition(state.recycledAccounts.isEmpty, "Recycled an account while work was in flight")
                }
                state.refreshingUsageAccountIDs = []
                state.recycleAccount(account)
                let recycledAt = state.recycledAccounts[0].recycledAt!
                state.recycleAccount(account)
                precondition(state.recycledAccounts[0].recycledAt == recycledAt, "Duplicate recycle changed its timestamp")
                precondition(state.visibleAccounts.isEmpty && state.accounts.count == 1)
                precondition(state.activeAccount?.id == account.id && state.activeAccount?.recycledAt == recycledAt)
                precondition(state.automaticUsageAccountIDs.isEmpty && WidgetData.lastSavedEmails.isEmpty)
                precondition(KeychainService.shared.backups[account.id.uuidString]?.token == "retained-fixture")
                precondition(defaults.data(forKey: "savedUsage." + account.id.uuidString) == cached)
                // Even a stale toggle/account value cannot reach a recycled account.
                state.automaticUsageAccountIDs.insert(account.id.uuidString)
                KeychainService.shared.email = account.email
                await state.refresh()
                await state.refreshAccountUsage(account)
                await state.switchTo(account)
                await state.reauthenticateAccount(account)
                await state.addAccount()
                precondition(state.errorMessage != nil && state.recycledAccounts.count == 1 && state.visibleAccounts.isEmpty)
                precondition(CLIUsageStore.reads.isEmpty && service.switched.isEmpty && service.loginCalls == 0 && service.captured.isEmpty)
                precondition(state.activeAccount?.id == account.id && state.activeAccount?.recycledAt == recycledAt)
                defaults.set(try JSONEncoder().encode(recycledAt), forKey: "expectedRecycledAt")
            } else {
                let recycledAt = try JSONDecoder().decode(Date.self, from: defaults.data(forKey: "expectedRecycledAt")!)
                precondition(state.visibleAccounts.isEmpty && state.recycledAccounts[0].recycledAt == recycledAt)
                precondition(state.activeAccount?.id == account.id && !state.backgroundUsageRefreshEnabled)
                let cached = defaults.data(forKey: "savedUsage." + account.id.uuidString)!
                KeychainService.shared.backups[account.id.uuidString] = AccountBackup(token: "retained-fixture", oauthAccount: [:])
                state.isLoggingIn = true
                state.restoreAccount(account)
                precondition(state.visibleAccounts.isEmpty, "Restored an account during login")
                state.isLoggingIn = false
                state.restoreAccount(account)
                state.restoreAccount(account)
                precondition(state.visibleAccounts.count == 1 && state.visibleAccounts[0].id == account.id && state.recycledAccounts.isEmpty)
                precondition(state.activeAccount?.id == account.id && state.activeAccount?.recycledAt == nil)
                precondition(state.automaticUsageAccountIDs.isEmpty && WidgetData.lastSavedEmails == [account.obfuscatedEmail])
                precondition(KeychainService.shared.backups[account.id.uuidString]?.token == "retained-fixture")
                precondition(defaults.data(forKey: "savedUsage." + account.id.uuidString) == cached)
                precondition(AppState().visibleAccounts.map(\.id) == [account.id])
                state.recycleAccount(account)
                KeychainService.shared.email = account.email
                state.claudeAvailable = true
                service.completesLogin = true
                await state.loginNewAccount()
                precondition(state.visibleAccounts.map(\.id) == [account.id] && state.accounts.count == 1,
                             "Explicit login duplicated or failed to restore the recycled identity")
                precondition(state.automaticUsageAccountIDs.isEmpty && service.captured.allSatisfy { $0 == account.id.uuidString })
                var legacy = try JSONSerialization.jsonObject(with: cached) as! [String: Any]
                legacy.removeValue(forKey: "fromCLI")
                legacy.removeValue(forKey: "source")
                defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "savedUsage." + account.id.uuidString)
                let historical = AppState()
                precondition(historical.accountUsage[account.id] != nil && historical.cliUsageAccountIDs.isEmpty,
                             "An old network sample was mislabeled as a CLI observation")
                // Missing cache remains unknown rather than triggering a fetch.
                defaults.removeObject(forKey: "savedUsage." + account.id.uuidString)
                let missing = AppState()
                precondition(missing.accountUsage[account.id] == nil && missing.accountUsageErrors[account.id] == nil)
                for corrupt in [Data("not JSON".utf8) as Any, "wrong storage type"] {
                    defaults.set(corrupt, forKey: "savedUsage." + account.id.uuidString)
                    let broken = AppState()
                    precondition(broken.accountUsage[account.id] == nil && broken.accountUsageSampledAt[account.id] == nil)
                    precondition(broken.accountUsageErrors[account.id] != nil, "Corrupt saved quota silently became zero or missing")
                }
                precondition(CLIUsageStore.reads.isEmpty, "Missing or corrupt saved quota triggered a local import")
                defaults.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
            }
        }
        precondition(defaults.synchronize(), "Could not persist the isolated test preferences")
        print("PASS: \(mode)")
    }

    @MainActor static func main() async throws {
        if let mode = CommandLine.arguments.dropFirst().first {
            if mode == "cleanup" {
                UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
                UserDefaults.standard.synchronize()
                return
            }
            try await checkSavedUsage(mode)
            return
        }
        // Argument-domain overrides avoid touching the installed app's preferences.
        UserDefaults.standard.setVolatileDomain([
            "backgroundUsageRefreshEnabled": true, "autoSwitchEnabled": false,
            "com.ccswitcher.accounts": Data("[]".utf8)
        ], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName) }
        let service = ClaudeService.shared
        let known = Account(email: "known@example.invalid", displayName: "Known", isActive: true)
        for existing in [[], [known]] {
            let state = AppState()
            state.accounts = existing
            state.activeAccount = existing.first
            state.claudeAvailable = true
            service.captured = []
            let login = Task { await state.loginNewAccount() }
            for _ in 0..<100 where !state.canCancelLogin { try await Task.sleep(for: .milliseconds(2)) }
            precondition(state.canCancelLogin, "Login did not become cancellable")
            for _ in 0..<100 where state.loginURL == nil { try await Task.sleep(for: .milliseconds(2)) }
            precondition(state.loginURL?.host == "claude.ai", "Login URL was not exposed for copying")
            state.cancelLogin()
            precondition(state.isLoggingIn && state.isCancellingLogin, "Cancellation released the credential lock early")
            await login.value
            precondition(!state.isLoggingIn && !state.isCancellingLogin && !state.canCancelLogin && state.loginTask == nil && state.loginURL == nil)
            precondition(state.activeAccount == nil && state.accounts.allSatisfy { !$0.isActive })
            precondition(state.suppressAutomaticAccountDiscovery)
            precondition(service.captured == existing.map { $0.id.uuidString }, "Cancelled login captured unknown credentials")
            await state.refresh() // The same entry point used by the timer.
            precondition(state.accounts.count == existing.count && state.activeAccount == nil)
            precondition(service.captured == existing.map { $0.id.uuidString }, "Timer recaptured a cancelled login")
            if let saved = existing.first {
                KeychainService.shared.backups[saved.id.uuidString] = AccountBackup(token: "known-fixture", oauthAccount: [:])
                await state.switchTo(saved)
                precondition(service.switched.count == 1 && service.switched[0].0 == nil && service.switched[0].1 == saved.id)
                precondition(state.activeAccount?.id == saved.id && !state.isSwitching)
                precondition(service.captured == [saved.id.uuidString], "Switch backed up an unknown source")
            }
        }
        print("PASS: cancellation cleans state, preserves unknown identity, and prevents timer capture")

        try await checkExplicitCLISession()
        try await checkLocalUsage(known)
        try await checkManualSwitchOnly()
    }
}
'''


def main():
    root = Path(__file__).resolve().parent.parent
    sources = [
        "AppState.swift", "AppState+Login.swift", "AppState+Usage.swift",
        "Models/Account.swift", "Models/String+Obfuscation.swift", "Models/UsageData.swift",
        "Models/ActivityData.swift", "Models/CostData.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="account-action-check-") as directory:
        work = Path(directory)
        harness = work / "Check.swift"
        harness.write_text(HARNESS)
        binary = work / ("account-check-" + uuid.uuid4().hex)
        subprocess.run([
            "swiftc", "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", str(work / "modules"),
            *[str(root / "CCSwitcher" / source) for source in sources],
            str(harness), "-o", str(binary),
        ], check=True, timeout=300)
        try:
            subprocess.run([str(binary)], check=True, timeout=15)
            for mode in ["cache-write", "cache-fail", "cache-read", "recycle-read"]:
                subprocess.run([str(binary), mode], check=True, timeout=15)
        finally:
            subprocess.run([str(binary), "cleanup"], check=True, timeout=15)


if __name__ == "__main__":
    main()
