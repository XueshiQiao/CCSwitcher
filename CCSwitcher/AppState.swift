import SwiftUI
import Combine
import WidgetKit

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    /// Only successful quota requests advance a sample's timestamp.
    @Published var accountUsageSampledAt: [UUID: Date] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published var canCancelLogin = false
    @Published var isCancellingLogin = false
    @Published var loginURL: URL?
    @Published var refreshingUsageAccountIDs: Set<UUID> = []
    @Published var usageNextRefreshAt: [UUID: Date] = [:]
    @Published var automaticUsageAccountIDs = Set(UserDefaults.standard.stringArray(forKey: "automaticUsageAccountIDs") ?? []) {
        didSet { UserDefaults.standard.set(Array(automaticUsageAccountIDs), forKey: "automaticUsageAccountIDs") }
    }
    var loginTask: Task<Void, Error>?
    var suppressAutomaticAccountDiscovery = false

    var backgroundUsageRefreshEnabled: Bool {
        accounts.contains { automaticUsageAccountIDs.contains($0.id.uuidString) }
    }
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var activityStats: ActivityStats = .empty

    // Store errors as special struct to surface in UI
    struct UsageErrorState {
        let isExpired: Bool
        let isRateLimited: Bool
        let message: String
    }
    
    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:]

    // MARK: - Services

    let claudeService = ClaudeService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    let keychain = KeychainService.shared

    private let accountsKey = "com.ccswitcher.accounts"
    private var refreshTimer: Timer?

    // MARK: - Usage polling state

    /// Re-entrancy guard: overlapping refreshes (timer + manual button + post-switch)
    /// would each burst per-account usage requests and trip the endpoint's rate limit.
    var isRefreshing = false

    /// Background opt-in fetches at most one due account per cycle.
    var usageFetchCursor = 0

    /// One switch (manual or automatic) may mutate live credentials at a time.
    /// `switchTo` suspends across subprocess and keychain work while the UI stays
    /// responsive, so without this a second switch — a user click during an
    /// auto-switch verification, or vice versa — could interleave keychain and
    /// ~/.claude.json writes with the first.
    @Published var isSwitching = false

    // MARK: - Auto-switch

    /// Whether proactive auto-switch is on (written by SettingsView via @AppStorage).
    private var autoSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoSwitchEnabled")
    }

    /// Utilization percentage at which we switch. Defaults to 90 when unset.
    private var autoSwitchThreshold: Double {
        let stored = UserDefaults.standard.double(forKey: "autoSwitchThreshold")
        return stored == 0 ? 90 : stored
    }

    /// A candidate must sit at least this far below the threshold to be eligible,
    /// so two accounts hovering at the line never ping-pong.
    private let autoSwitchHysteresis: Double = 10

    /// Minimum gap between two automatic switches, to avoid rapid flip-flopping.
    private let autoSwitchCooldown: TimeInterval = 300

    var lastAutoSwitchAt: Date?
    private var isEvaluatingAutoSwitch = false

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts from UserDefaults...")
        loadAccounts()
        loadSavedUsage()
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    // MARK: - Refresh

    /// Refresh everything, then decide whether to auto-switch.
    ///
    /// The two halves are deliberately separate: `refreshData()` holds the
    /// `isRefreshing` re-entrancy guard for its whole body, so evaluating
    /// auto-switch *inside* it would mean the `switchTo() -> refresh()` that
    /// follows an automatic switch gets swallowed by that guard — leaving the
    /// spinner stuck and the new active account showing pre-switch numbers.
    /// And when `refreshData()` did NOT run (login in progress, another refresh
    /// already running), auto-switch must not be evaluated either: it would act
    /// on state mid-mutation — swapping credentials during a login, or deciding
    /// on samples a concurrent refresh is rewriting.
    func refresh() async {
        guard await refreshData() else { return }
        await evaluateAutoSwitch()
    }

    /// Returns true only when a full refresh actually ran.
    private func refreshData() async -> Bool {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return false
        }
        guard !isRefreshing else {
            log.info("[refresh] Skipping: refresh already in progress")
            return false
        }
        isRefreshing = true
        defer { isRefreshing = false }
        isLoading = true
        errorMessage = nil

        claudeAvailable = await claudeService.isClaudeAvailable()
        log.info("[refresh] Claude available: \(self.claudeAvailable)")

        if claudeAvailable {
            do {
                let status = try await claudeService.getAuthStatus()
                updateActiveAccount(from: status)
            } catch {
                log.error("[refresh] getAuthStatus failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }

        // Passive token health check (no CLI calls, keychain reads only)
        diagnoseTokenHealth()

        // Quota requests require explicit background opt-in.
        if await refreshUsageCooldowns(), backgroundUsageRefreshEnabled {
            await refreshNextAccountUsage()
        }
        lastUsageRefresh = Date()

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        // JSONL parsing: walk filesystem once via the shared cache, then
        // pull aggregated outputs. The actor's executor is off the main
        // thread, so awaiting these does not block the UI.
        await SessionParseCacheV2.shared.refreshFromFilesystem()
        let cost = await costParser.getCostSummary()
        let activity = await activityParser.getTodayStats()
        costSummary = cost
        activityStats = activity

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", cost.todayCost)) turns=\(activity.conversationTurns)")

        updateWidgetData()
        isLoading = false
        return true
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Account Management

    func addAccount() async {
        guard !isLoggingIn, !isSwitching, !isRefreshing, refreshingUsageAccountIDs.isEmpty else { return }
        isSwitching = true
        defer { isSwitching = false }
        log.info("[addAccount] Starting add current account flow...")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[addAccount] Aborted: Claude CLI not found")
            return
        }

        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Not logged in to Claude. Run 'claude auth login' first.", bundle: L10n.bundle)
                log.error("[addAccount] Aborted: not logged in")
                return
            }
            guard let email = status.email else {
                errorMessage = shadowedIdentityMessage(status)
                log.error("[addAccount] Aborted: CLI reports authMethod=\(status.authMethod ?? "nil") without an account identity")
                return
            }
            log.info("[addAccount] Current auth: logged in, sub=\(status.subscriptionType ?? "nil")")

            if accounts.contains(where: { $0.email == email }) {
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                log.warning("[addAccount] Aborted: duplicate account")
                return
            }

            var account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: accounts.isEmpty
            )
            log.info("[addAccount] Created account model, id=\(account.id)")

            log.info("[addAccount] Capturing token from keychain...")
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture auth token from keychain", bundle: L10n.bundle)
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            if activeAccount == nil {
                account.isActive = true
                activeAccount = account
                log.info("[addAccount] First account, setting as active")
            }

            accounts.append(account)
            suppressAutomaticAccountDiscovery = false
            saveAccounts()
            log.info("[addAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addAccount] Error: \(error.localizedDescription)")
        }
    }

    func updateAccountLabel(_ account: Account, label: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        if accounts[index].isActive {
            activeAccount = accounts[index]
        }
        saveAccounts()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    func removeAccount(_ account: Account) {
        log.info("[removeAccount] Removing account \(account.id)")
        guard !isLoggingIn, !isSwitching, refreshingUsageAccountIDs.isEmpty else { return }
        keychain.removeAccountBackup(forAccountId: account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        automaticUsageAccountIDs.remove(account.id.uuidString)
        // Drop every per-account cache too, or a re-added account inherits the
        // removed one's readings, error banner and rate-limit park.
        accountUsage[account.id] = nil
        accountUsageSampledAt[account.id] = nil
        accountUsageErrors[account.id] = nil
        usageNextRefreshAt[account.id] = nil
        UserDefaults.standard.removeObject(forKey: "savedUsage." + account.id.uuidString)
        if account.isActive, let first = accounts.first {
            accounts[accounts.startIndex].isActive = true
            activeAccount = accounts.first
            log.info("[removeAccount] Removed active account, switching to first remaining")
            Task { await switchTo(first) }
        }
        saveAccounts()
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    func switchTo(_ account: Account) async {
        let currentActive = activeAccount
        guard currentActive?.id != account.id else {
            log.info("[switchTo] No switch needed (same account)")
            return
        }

        log.info("[switchTo] ===== Switching to \(account.id) =====")

        // One credential mutation at a time: a switch already in flight (its
        // awaits leave the main actor free) or a running login must finish
        // before another switch may touch the keychain and ~/.claude.json.
        guard !isSwitching, !isLoggingIn, !isRefreshing, refreshingUsageAccountIDs.isEmpty else {
            log.warning("[switchTo] Skipped: another switch or a login is in progress")
            return
        }
        isSwitching = true
        defer { isSwitching = false }

        // Pre-switch: resolve the target's backup ONCE and hand it down.
        // "The store is briefly unreadable" and "no backup exists" are
        // different problems with different fixes — don't send the user to
        // re-authenticate over a locked keychain. Passing the resolved backup
        // into switchAccount also removes its second lookup, which collapsed
        // exactly this distinction one layer down.
        let targetBackup: AccountBackup
        switch keychain.lookupAccountBackup(forAccountId: account.id.uuidString) {
        case .found(let backup):
            targetBackup = backup
        case .missing:
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return
        case .storeUnavailable:
            log.error("[switchTo] ABORT: backup store unreadable right now")
            errorMessage = String(localized: "Credential storage is temporarily unavailable. Try again shortly.", bundle: L10n.bundle)
            return
        }

        // Any switch, deliberate or automatic, restarts the auto-switch cooldown:
        // a user who knowingly picks an account sitting at 95% must not be
        // auto-switched away from it seconds later by the refresh that follows.
        lastAutoSwitchAt = Date()

        isLoading = true
        do {
            let outcome = try await claudeService.switchAccount(from: currentActive, to: account, targetBackup: targetBackup)

            for i in accounts.indices {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            saveAccounts()

            await refresh()
            // `refresh()` clears errorMessage, so surface the warning afterwards.
            if let shadowedBy = outcome.shadowedBy {
                errorMessage = String(localized: "Switched to \(account.email), but the Claude CLI is authenticating via \(shadowedBy) instead of the stored login, so it will not use this account.", bundle: L10n.bundle)
            }
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-switch

    /// Whether an account can be switched to right now: it must have a stored
    /// backup token and not be flagged expired (an expired backup would fail the
    /// switch verification, or silently swap in a dead session).
    private func isSwitchable(_ account: Account) -> Bool {
        guard keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil else { return false }
        if accountUsageErrors[account.id] != nil { return false }
        return true
    }

    /// Evaluate whether the active account has reached the threshold and, if so,
    /// switch to the same-provider account with the most quota left.
    /// Called after every completed refresh. Safe to call repeatedly.
    ///
    /// Use only samples younger than 15 minutes. Verification never sends
    /// extra quota requests, and manual-only mode does not auto-switch.
    private func evaluateAutoSwitch() async {
        guard backgroundUsageRefreshEnabled, autoSwitchEnabled, !isEvaluatingAutoSwitch else { return }
        guard !isLoggingIn, !isSwitching, refreshingUsageAccountIDs.isEmpty, let active = activeAccount else { return }

        // Cooldown: never auto-switch more than once per window.
        if let last = lastAutoSwitchAt, Date().timeIntervalSince(last) < autoSwitchCooldown {
            return
        }

        // Only consider same-provider accounts (a Claude switch never touches Codex/Gemini).
        let candidates = accounts.filter { $0.provider == active.provider && $0.id != active.id }
        let recentUsage = accountUsage.filter { id, _ in
            guard let sampledAt = accountUsageSampledAt[id] else { return false }
            return Date().timeIntervalSince(sampledAt) < 15 * 60
        }
        let ranked = AutoSwitchEngine.rankedTargets(
            active: active,
            candidates: candidates,
            usageByAccount: recentUsage,
            isSwitchable: { [unowned self] in self.isSwitchable($0) },
            activeSampledThisCycle: false,
            threshold: autoSwitchThreshold,
            hysteresisPct: autoSwitchHysteresis
        )
        guard !ranked.isEmpty else { return }

        isEvaluatingAutoSwitch = true
        defer { isEvaluatingAutoSwitch = false }

        let activeUtil = AutoSwitchEngine.bindingUtilization(accountUsage[active.id]) ?? -1
        let ceiling = autoSwitchThreshold - autoSwitchHysteresis
        log.info("[autoSwitch] Active \(active.id) at \(String(format: "%.0f", activeUtil))% (threshold \(String(format: "%.0f", self.autoSwitchThreshold))%); \(ranked.count) candidate(s)")

        // Background opt-in permits switching from recent samples, never extra HTTP probes.
        for target in ranked {
            let usage = recentUsage[target.id]
            guard let verifiedUtil = AutoSwitchEngine.bindingUtilization(usage),
                  verifiedUtil <= ceiling else {
                log.info("[autoSwitch] Candidate \(target.id) failed verification (\(AutoSwitchEngine.bindingUtilization(usage).map { String(format: "%.0f%%", $0) } ?? "no reading")); trying next")
                continue
            }

            log.info("[autoSwitch] Switching to \(target.id), verified at \(String(format: "%.0f", verifiedUtil))%")
            lastAutoSwitchAt = Date()
            // switchTo() calls refresh() -> evaluateAutoSwitch() again, but the
            // re-entrancy flag + the freshly-set cooldown make that a no-op.
            // The active account visibly changes in the menu bar as feedback.
            await switchTo(target)
            return
        }
        log.info("[autoSwitch] Threshold reached but no candidate verified; staying put")
    }

    // MARK: - Diagnostics

    /// Message for the case where the CLI *is* authenticated but reports no
    /// account, because a credential source outranking the stored claude.ai login
    /// is in play. Without this the user only saw "Not logged in" / "Login did not
    /// complete" and re-authorized in a loop that could never help (issue #18).
    func shadowedIdentityMessage(_ status: AuthStatus) -> String {
        let method = status.shadowingAuthMethod ?? "unknown"
        return String(localized: "Claude CLI is authenticating via \(method) instead of a stored claude.ai login, so it reports no account. Unset ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_PROFILE and remove any apiKeyHelper, then try again.", bundle: L10n.bundle)
    }

    /// Passive health check — verifies backup existence and identity consistency.
    private func diagnoseTokenHealth() {
        guard !accounts.isEmpty else { return }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(self.accounts.count), active: \(self.activeAccount?.email ?? "none")")

        // Check live oauthAccount identity
        if let liveOAuth = keychain.readOAuthAccount() {
            let liveEmail = (liveOAuth["emailAddress"]?.value as? String) ?? "?"
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        // Check each account has a backup
        for account in accounts {
            if let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) {
                let backupEmail = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
                log.info("[diagnose] Backup [\(account.email)]: OK (email=\(backupEmail))")
            } else {
                log.warning("[diagnose] Backup [\(account.email)]: MISSING — switch will fail")
            }
        }

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - Widget

    func updateWidgetData() {
        let widgetAccounts = accounts.map { account in
            let usage = accountUsage[account.id]
            let error = accountUsageErrors[account.id]
            return WidgetAccountData(
                email: account.displayEmail(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                displayName: account.effectiveDisplayName(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                subscriptionType: account.displaySubscriptionType,
                isActive: account.isActive,
                sessionUtilization: usage?.fiveHour?.utilization,
                sessionResetTime: usage?.fiveHour?.resetTimeString,
                weeklyUtilization: usage?.sevenDay?.utilization,
                weeklyResetTime: usage?.sevenDay?.resetTimeString,
                extraUsageEnabled: usage?.extraUsage?.isEnabled,
                hasError: error != nil,
                errorMessage: error?.message
            )
        }

        let data = WidgetData(
            accounts: widgetAccounts,
            todayCost: costSummary.todayCost,
            conversationTurns: activityStats.conversationTurns,
            activeCodingTime: activityStats.activeCodingTimeString,
            linesWritten: activityStats.linesWritten,
            modelUsage: activityStats.modelUsage,
            lastUpdated: Date()
        )
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("[updateWidgetData] Widget data saved and timelines reloaded")
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        activeAccount = accounts.first(where: \.isActive)
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    func saveAccounts(refreshWidget: Bool = false) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
        if refreshWidget {
            updateWidgetData()
        }
    }

    private func updateActiveAccount(from status: AuthStatus) {
        guard status.loggedIn, let email = status.email else { return }

        if let index = accounts.firstIndex(where: { $0.email == email }) {
            for i in accounts.indices {
                accounts[i].isActive = (i == index)
            }
            accounts[index].orgName = status.orgName
            accounts[index].subscriptionType = status.subscriptionType
            activeAccount = accounts[index]
            saveAccounts()
            log.info("[updateActiveAccount] Matched existing account at index \(index)")
        } else if accounts.isEmpty && !suppressAutomaticAccountDiscovery {
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            accounts.append(account)
            activeAccount = account
            _ = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            saveAccounts()
            log.info("[updateActiveAccount] Auto-created first account, id=\(account.id)")
        } else {
            log.info("[updateActiveAccount] Logged-in account not in our list (might be new)")
        }
    }
}
