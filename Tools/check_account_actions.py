#!/usr/bin/env python3
"""Offline AppState regression check: uv run python3 Tools/check_account_actions.py.

Real AppState and models run against in-memory CLI, credential, filesystem and
widget boundaries. Reintroducing post-cancel capture, global quota locks, ignoring
per-account automatic refresh preferences, losing saved quota across processes,
or replacing a failed quota sample fails.
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
    var backups: [String: AccountBackup] = [:]
    func readOAuthAccount() -> [String: AnyCodable]? { ["emailAddress": AnyCodable(email)] }
    func readClaudeToken() -> String? { "active-fixture" }
    func getAccountBackup(forAccountId id: String) -> AccountBackup? { backups[id] }
    func removeAccountBackup(forAccountId id: String) { backups[id] = nil }
    enum Lookup { case found(AccountBackup), missing, storeUnavailable }
    func lookupAccountBackup(forAccountId id: String) -> Lookup {
        backups[id].map { .found($0) } ?? .missing
    }
}

@MainActor final class ClaudeService {
    static let shared = ClaudeService()
    enum UsageError: Error {
        case expired, network(String), decode(String), rateLimited(retryAfter: TimeInterval?), forbidden(String)
    }
    var captured: [String] = []
    var requested: [(UUID, String)] = []
    var usageError: UsageError?
    var delayUsage = false
    var authCalls = 0
    var loginCalls = 0
    var switched: [(UUID?, UUID)] = []
    static let usageJSON = #"{"five_hour":{"utilization":23,"resets_at":"2026-10-06T18:00:00Z"},"seven_day":{"utilization":42},"seven_day_oauth_apps":{"utilization":4},"seven_day_opus":{"utilization":5},"seven_day_sonnet":{"utilization":6},"seven_day_cowork":{"utilization":7},"iguana_necktie":{"utilization":8},"extra_usage":{"is_enabled":true,"monthly_limit":100,"used_credits":12,"utilization":12}}"#
    func isClaudeAvailable() async -> Bool { true }
    func getAuthStatus() async throws -> AuthStatus {
        authCalls += 1
        return AuthStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: nil,
                          email: KeychainService.shared.email, orgId: nil, orgName: nil, subscriptionType: nil)
    }
    func login(onURL: @escaping @Sendable (URL) async -> Void) async throws {
        loginCalls += 1
        await onURL(URL(string: "https://claude.ai/oauth/authorize?state=offline")!)
        try await Task.sleep(for: .seconds(30))
    }
    func captureCurrentCredentials(forAccountId id: String) -> Bool { captured.append(id); return true }
    static func extractAccessToken(from token: String) -> String? { token }
    func getUsageLimits(accessToken: String, accountID: UUID) async throws -> UsageAPIResponse {
        requested.append((accountID, accessToken))
        if delayUsage { try await Task.sleep(for: .milliseconds(200)) }
        if let usageError { throw usageError }
        return try JSONDecoder().decode(UsageAPIResponse.self, from: Data(Self.usageJSON.utf8))
    }
    struct SwitchOutcome { let shadowedBy: String? }
    func switchAccount(from source: Account?, to target: Account, targetBackup: AccountBackup) async throws -> SwitchOutcome {
        switched.append((source?.id, target.id))
        KeychainService.shared.email = target.email
        return SwitchOutcome(shadowedBy: nil)
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
    func save() {}
}
struct WidgetCenter: Sendable {
    static let shared = WidgetCenter()
    func reloadAllTimelines() {}
}

@main struct AccountCheck {
    @MainActor static func checkSavedUsage(_ mode: String) async throws {
        let defaults = UserDefaults.standard
        let service = ClaudeService.shared
        defaults.setVolatileDomain(["autoSwitchEnabled": false], forName: UserDefaults.argumentDomain)
        if mode == "cache-write" {
            let state = AppState()
            let account = Account(email: "saved@example.invalid", displayName: "Saved")
            state.accounts = [account]
            state.saveAccounts()
            KeychainService.shared.backups[account.id.uuidString] = AccountBackup(token: "saved-fixture", oauthAccount: [:])
            await state.refreshAccountUsage(account)
            precondition(service.requested.count == 1 && state.accountUsage[account.id] != nil)
            defaults.set(try JSONEncoder().encode(state.accountUsageSampledAt[account.id]!), forKey: "expectedSampleTime")
        } else {
            let state = AppState()
            precondition(state.accounts.count == 1)
            let account = state.accounts[0]
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let expected = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(ClaudeService.usageJSON.utf8))
            let actualJSON = try encoder.encode(state.accountUsage[account.id]!)
            let expectedJSON = try encoder.encode(expected)
            precondition(actualJSON == expectedJSON, "Restart lost saved quota fields")
            let expectedTime = try JSONDecoder().decode(Date.self, from: defaults.data(forKey: "expectedSampleTime")!)
            precondition(state.accountUsageSampledAt[account.id] == expectedTime, "Restart changed the sample age")
            precondition(service.requested.isEmpty, "Restoring cached quota sent a request")
            if mode == "cache-fail" {
                KeychainService.shared.backups[account.id.uuidString] = AccountBackup(token: "saved-fixture", oauthAccount: [:])
                service.usageError = .network("offline fixture")
                await state.refreshAccountUsage(account)
                precondition(state.accountUsageErrors[account.id] != nil)
                precondition(state.accountUsageSampledAt[account.id] == expectedTime)
            } else {
                state.removeAccount(account)
                precondition(state.accountUsage[account.id] == nil && state.accountUsageSampledAt[account.id] == nil)
                precondition(defaults.object(forKey: "savedUsage." + account.id.uuidString) == nil, "Removing the account left its saved usage")
                // Reload the same identity without a sample; absence must stay unknown.
                state.accounts = [account]
                state.saveAccounts()
                let missing = AppState()
                precondition(missing.accountUsage[account.id] == nil && missing.accountUsageErrors[account.id] == nil)
                for corrupt in [Data("not JSON".utf8) as Any, "wrong storage type"] {
                    defaults.set(corrupt, forKey: "savedUsage." + account.id.uuidString)
                    let broken = AppState()
                    precondition(broken.accountUsage[account.id] == nil && broken.accountUsageSampledAt[account.id] == nil)
                    precondition(broken.accountUsageErrors[account.id] != nil, "Corrupt saved quota silently became zero or missing")
                }
                precondition(service.requested.isEmpty, "Missing or corrupt saved quota triggered a request")
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

        let state = AppState()
        let target = Account(email: "target@example.invalid", displayName: "Target")
        state.accounts = [known, target]
        state.activeAccount = known
        KeychainService.shared.email = known.email
        KeychainService.shared.backups[target.id.uuidString] = AccountBackup(token: "target-fixture", oauthAccount: [:])
        service.requested = []
        service.authCalls = 0
        service.captured = []
        let old = try JSONDecoder().decode(UsageAPIResponse.self, from: Data("{\"five_hour\":{\"utilization\":72}}".utf8))
        let sampledAt = Date(timeIntervalSince1970: 1700000000)
        state.accountUsage[target.id] = old
        state.accountUsageSampledAt[target.id] = sampledAt
        let previousLoginCalls = service.loginCalls
        for error in [ClaudeService.UsageError.expired, .network("offline fixture")] {
            service.usageError = error
            await state.refreshAccountUsage(target)
            precondition(state.accountUsage[target.id]?.fiveHour?.utilization == 72)
            precondition(state.accountUsageSampledAt[target.id] == sampledAt)
            precondition(state.accountUsageErrors[target.id] != nil && state.refreshingUsageAccountIDs.isEmpty)
        }
        service.usageError = nil
        await state.refreshAccountUsage(target)
        precondition(state.accountUsage[target.id]?.fiveHour?.utilization == 23)
        precondition(state.accountUsageSampledAt[target.id]! > sampledAt && state.accountUsageErrors[target.id] == nil)
        precondition(service.requested.count == 3 && service.requested.allSatisfy { $0.0 == target.id && $0.1 == "target-fixture" })
        precondition(service.authCalls == 0 && service.loginCalls == previousLoginCalls && service.captured.isEmpty)
        precondition(service.switched.count == 1, "Manual quota refresh switched an account")
        precondition(state.activeAccount?.id == known.id && state.accountUsage[known.id] == nil)
        print("PASS: manual quota fetch only targets one account; failure retains sample and timestamp without login")

        service.requested = []
        await state.refresh()
        precondition(service.requested.isEmpty && !state.isLoading && !state.isRefreshing)
        print("PASS: default periodic refresh does not request quota, even with the obsolete global setting enabled")

        state.automaticUsageAccountIDs.insert(target.id.uuidString)
        precondition(AppState().automaticUsageAccountIDs == [target.id.uuidString], "Enabled preference was not persisted")
        await state.refresh()
        precondition(service.requested.map { $0.0 } == [target.id], "Automatic refresh ignored the per-account switch")
        state.automaticUsageAccountIDs.remove(target.id.uuidString)
        precondition(AppState().automaticUsageAccountIDs.isEmpty, "Disabled preference was not persisted")
        service.requested = []
        await state.refresh()
        precondition(service.requested.isEmpty, "Disabled account was automatically refreshed")
        await state.refreshAccountUsage(target)
        precondition(service.requested.map { $0.0 } == [target.id], "Disabling automatic refresh blocked manual refresh")
        print("PASS: per-account switch persists, restricts automatic refresh, and leaves manual refresh available")

        service.requested = []
        service.delayUsage = true
        state.isRefreshing = true // Local statistics work must not lock quota buttons.
        let firstRequest = Task { await state.refreshAccountUsage(target) }
        for _ in 0..<100 where service.requested.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        precondition(state.refreshingUsageAccountIDs == [target.id])
        await state.refreshAccountUsage(target)
        precondition(service.requested.count == 1, "Duplicate account request was admitted")
        await state.refreshAccountUsage(known)
        await firstRequest.value
        state.isRefreshing = false
        precondition(service.requested.map { $0.0 } == [target.id, known.id], "Another account or local statistics blocked manual quota refresh")
        precondition(state.refreshingUsageAccountIDs.isEmpty)
        print("PASS: in-flight state only disables the same account; statistics refresh does not block manual quota")
    }
}
'''


def main():
    root = Path(__file__).resolve().parent.parent
    sources = [
        "AppState.swift", "AppState+Login.swift", "AppState+Usage.swift",
        "Services/UsageRequestLimiter.swift", "Services/AutoSwitchEngine.swift",
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
        ], check=True, timeout=120)
        try:
            subprocess.run([str(binary)], check=True, timeout=15)
            for mode in ["cache-write", "cache-fail", "cache-read"]:
                subprocess.run([str(binary), mode], check=True, timeout=15)
        finally:
            subprocess.run([str(binary), "cleanup"], check=True, timeout=15)


if __name__ == "__main__":
    main()
