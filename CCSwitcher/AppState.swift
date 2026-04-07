import SwiftUI
import Combine

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
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
    @Published var cachedUsage: [UUID: CachedUsageEntry] = [:]

    /// Whether auto-switch is enabled (persisted via AppStorage in SettingsView)
    @AppStorage("autoSwitchEnabled") var autoSwitchEnabled = false
    /// Usage threshold (0-100) that triggers auto-switch
    @AppStorage("autoSwitchThreshold") var autoSwitchThreshold = 90

    // MARK: - Services

    private let claudeService = ClaudeService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    private let keychain = KeychainService.shared

    private let accountsKey = "com.ccswitcher.accounts"
    private let usageCacheKey = "com.ccswitcher.usageCache"
    private var refreshTimer: Timer?
    private var lastAutoSwitchTime: Date?
    private let autoSwitchCooldown: TimeInterval = 600
    /// Track last-abandoned account to prevent A→B→A oscillation
    private var lastAbandonedAccountId: UUID?

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts from UserDefaults...")
        loadAccounts()
        loadUsageCache()
        // Pre-populate accountUsage from cache so UI renders immediately
        // Use even stale cache — better to show old data than nothing
        for (id, entry) in cachedUsage {
            accountUsage[id] = entry.usage
        }

        log.info("[init] Loaded \(self.accounts.count) accounts, \(self.cachedUsage.count) cached, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    // MARK: - Refresh

    /// When true, `refresh()` skips `autoSwitchIfNeeded()` to prevent recursion.
    private var isAutoSwitching = false

    private var isRefreshing = false

    func refresh() async {
        guard !isRefreshing else {
            log.info("[refresh] Skipping: already refreshing")
            return
        }
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return
        }
        isRefreshing = true
        isLoading = true
        defer { isLoading = false; isRefreshing = false }
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

        // Fetch usage limits for all accounts
        await fetchAllAccountUsage()
        lastUsageRefresh = Date()

        // Auto-switch when current account exceeds threshold (skip if called from switchTo during auto-switch)
        if !isAutoSwitching {
            await autoSwitchIfNeeded()
        }

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        // Heavy JSONL parsing off main thread
        let parser = costParser
        let actParser = activityParser
        let cost = await Task.detached { parser.getCostSummary() }.value
        let activity = await Task.detached { actParser.getTodayStats() }.value
        costSummary = cost
        activityStats = activity

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", cost.todayCost)) turns=\(activity.conversationTurns)")
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
        log.info("[addAccount] Starting add current account flow...")
        guard claudeAvailable else {
            errorMessage = "Claude CLI not found"
            log.error("[addAccount] Aborted: Claude CLI not found")
            return
        }

        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = "Not logged in to Claude. Run 'claude auth login' first."
                log.error("[addAccount] Aborted: not logged in")
                return
            }
            log.info("[addAccount] Current auth: logged in, sub=\(status.subscriptionType ?? "nil")")

            if accounts.contains(where: { $0.email == email }) {
                errorMessage = "Account already exists"
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
                errorMessage = "Could not capture auth token from keychain"
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            if accounts.isEmpty {
                account.isActive = true
                activeAccount = account
                log.info("[addAccount] First account, setting as active")
            }

            accounts.append(account)
            saveAccounts()
            log.info("[addAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addAccount] Error: \(error.localizedDescription)")
        }
    }

    func loginNewAccount() async {
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard claudeAvailable else {
            errorMessage = "Claude CLI not found"
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            return
        }

        isLoggingIn = true
        defer { isLoggingIn = false }
        errorMessage = nil

        do {
            // 1. Back up current account (token + oauthAccount) before login overwrites them
            if let current = activeAccount {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                let backed = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
                log.info("[loginNewAccount] Step 1: Backup result: \(backed)")
            } else {
                log.info("[loginNewAccount] Step 1: No active account, skipping backup")
            }

            // 2. Run `claude auth login` — this overwrites both keychain and ~/.claude.json
            log.info("[loginNewAccount] Step 2: Running `claude auth login`...")
            try await claudeService.login()
            log.info("[loginNewAccount] Step 2: Login process completed")

            // 3. Read the new identity from ~/.claude.json
            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = "Login did not complete"
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                return
            }
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            // 4. Check for duplicate — if exists, refresh its backup and usage
            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup")
                _ = claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString)

                // Clear expired error and mark as active
                accountUsageErrors.removeValue(forKey: accounts[existing].id)

                // Ensure this account is marked active
                for i in accounts.indices {
                    accounts[i].isActive = (i == existing)
                }
                activeAccount = accounts[existing]
                saveAccounts()

                // Must clear before refresh() — refresh() has `guard !isLoggingIn` that would skip otherwise.
                // The defer at function scope will set it to false again harmlessly.
                isLoggingIn = false
                await refresh()
                log.info("[loginNewAccount] Step 4: Existing account credentials refreshed and usage updated")
                return
            }

            // 5. Create new account and capture credentials (token + oauthAccount)
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            log.info("[loginNewAccount] Step 5: Created account, id=\(account.id)")

            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = "Could not capture credentials"
                log.error("[loginNewAccount] Step 5: Capture failed!")
                return
            }

            // 6. Mark new account as active
            for i in accounts.indices {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            saveAccounts()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            isLoggingIn = false
            await refresh()
            log.info("[loginNewAccount] ===== Login completed =====")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
        }
    }

    func removeAccount(_ account: Account) {
        log.info("[removeAccount] Removing account \(account.id)")
        keychain.removeAccountBackup(forAccountId: account.id.uuidString)
        cachedUsage.removeValue(forKey: account.id)
        saveUsageCache()
        accounts.removeAll { $0.id == account.id }
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
        guard let currentActive = activeAccount, currentActive.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return
        }

        log.info("[switchTo] ===== Switching from \(currentActive.email) to \(account.email) =====")

        // Pre-switch: verify target has a backup
        guard keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = "No stored credentials for \(account.email). Use re-authenticate to fix."
            return
        }

        isLoading = true
        do {
            try await claudeService.switchAccount(from: currentActive, to: account)

            for i in accounts.indices {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            saveAccounts()

            await refresh()
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = "Claude CLI not found"
            return
        }

        isLoggingIn = true
        defer { isLoggingIn = false }
        errorMessage = nil

        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                _ = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
            }

            // 2. Run login
            log.info("[reauth] Running `claude auth login`...")
            try await claudeService.login()

            // 3. Verify the login result matches the target account
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = "Login did not complete"
                return
            }

            guard email == account.email else {
                errorMessage = "Logged in as \(email), but expected \(account.email). Credentials not updated."
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                return
            }

            // 4. Capture the fresh token and clear expired state
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            log.info("[reauth] Token capture result: \(captured)")
            accountUsageErrors.removeValue(forKey: account.id)

            // 5. Update account metadata
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                saveAccounts()
            }

            isLoggingIn = false
            await refresh()
            log.info("[reauth] ===== Re-authentication completed =====")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[reauth] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto Switch

    private func autoSwitchIfNeeded() async {
        guard autoSwitchEnabled else { return }
        guard let current = activeAccount else { return }
        guard accounts.count > 1 else { return }

        // Anti-oscillation cooldown
        if let lastSwitch = lastAutoSwitchTime,
           Date().timeIntervalSince(lastSwitch) < autoSwitchCooldown {
            log.info("[autoSwitch] Cooldown active, skipping")
            return
        }

        let currentUtilization = resolveSessionUtilization(for: current.id) ?? 0
        guard currentUtilization >= Double(autoSwitchThreshold) else { return }

        log.info("[autoSwitch] Current account \(current.email) at \(Int(currentUtilization))% (threshold: \(autoSwitchThreshold)%), looking for alternative...")

        // Exclude expired tokens (truly unknown); allow 429'd accounts (have cache)
        // Deprioritize (don't exclude) the last-abandoned account to prevent A→B→A oscillation
        let threshold = Double(autoSwitchThreshold)
        let candidates = accounts
            .filter { $0.id != current.id }
            .filter { !(accountUsageErrors[$0.id]?.isExpired ?? false) }
            .compactMap { account -> (Account, Double, TimeInterval)? in
                guard let util = resolveSessionUtilization(for: account.id) else { return nil }
                let resetInterval = resolveWeeklyResetInterval(for: account.id)
                return (account, util, resetInterval)
            }
            .filter { $0.1 < threshold }
            .sorted { a, b in
                // Primary: lower utilization. Tiebreaker (<10% diff): sooner weekly reset
                if abs(a.1 - b.1) < 10.0 {
                    return a.2 < b.2
                }
                return a.1 < b.1
            }

        // Prefer non-abandoned candidate; fall back to abandoned only if it's the sole option
        let candidate = candidates.first(where: { $0.0.id != lastAbandonedAccountId })
            ?? candidates.first

        guard let (target, targetUtil, _) = candidate else {
            log.info("[autoSwitch] No suitable account found (all above threshold or unavailable)")
            return
        }

        log.info("[autoSwitch] Switching to \(target.email) at \(Int(targetUtil))%")
        lastAbandonedAccountId = current.id
        lastAutoSwitchTime = Date()
        isAutoSwitching = true
        defer { isAutoSwitching = false }
        await switchTo(target)
    }

    /// Resolve session utilization: live data first, then cache with reset-awareness.
    private func resolveSessionUtilization(for accountId: UUID) -> Double? {
        if accountUsageErrors[accountId] == nil,
           let usage = accountUsage[accountId],
           let util = usage.fiveHour?.utilization {
            return util
        }
        return cachedUsage[accountId]?.effectiveSessionUtilization()
    }

    /// Time until weekly reset (seconds). Returns .infinity if unknown.
    private func resolveWeeklyResetInterval(for accountId: UUID) -> TimeInterval {
        let usage = accountUsage[accountId] ?? cachedUsage[accountId]?.usage
        guard let resetDate = usage?.sevenDay?.resetsAtDate else { return .infinity }
        let interval = resetDate.timeIntervalSinceNow
        return interval > 0 ? interval : 0
    }

    // MARK: - Usage

    private func fetchAllAccountUsage() async {
        accountUsageErrors.removeAll()
        for account in accounts {
            let tokenJSON: String?
            if account.isActive {
                tokenJSON = keychain.readClaudeToken()
            } else {
                tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
            }
            guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
                log.warning("[fetchUsage] No token for \(account.email), skipping")
                continue
            }
            // Stagger requests to avoid 429 rate limiting (1.5s between each)
            if account.id != accounts.first?.id {
                try? await Task.sleep(for: .milliseconds(1500))
            }
            do {
                let usage = try await claudeService.getUsageLimits(accessToken: accessToken)
                accountUsage[account.id] = usage
                cachedUsage[account.id] = CachedUsageEntry(usage: usage, fetchedAt: Date())
                accountUsageErrors[account.id] = nil
                log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            } catch ClaudeService.UsageError.expired {
                log.warning("[fetchUsage] Token expired for \(account.email)")
                if account.isActive {
                    // Try refreshing via CLI: run `auth status` which may internally refresh the token
                    var recovered = false
                    do {
                        _ = try await claudeService.getAuthStatus()
                        log.info("[fetchUsage] Auth status check done for active account.")
                        if let refreshedJSON = keychain.readClaudeToken(),
                           let refreshedToken = ClaudeService.extractAccessToken(from: refreshedJSON),
                           refreshedToken != accessToken,
                           let usage = try? await claudeService.getUsageLimits(accessToken: refreshedToken) {
                            accountUsage[account.id] = usage
                            cachedUsage[account.id] = CachedUsageEntry(usage: usage, fetchedAt: Date())
                            accountUsageErrors[account.id] = nil
                            // Update backup with the refreshed token
                            _ = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
                            log.info("[fetchUsage] Recovered \(account.email) via token refresh.")
                            recovered = true
                        }
                    } catch {
                        log.error("[fetchUsage] Auth status check failed: \(error.localizedDescription)")
                    }
                    if !recovered {
                        log.warning("[fetchUsage] Could not refresh token for active account \(account.email)")
                        fallbackToCache(for: account.id)
                        accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: "Token expired. Click ↻ to re-authenticate.")
                    }
                } else {
                    log.info("[fetchUsage] Non-active account \(account.email) token expired.")
                    fallbackToCache(for: account.id)
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: "Token expired. Switch to refresh.")
                }
            } catch {
                log.error("[fetchUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
                let is429 = (error as? ClaudeService.UsageError).flatMap {
                    if case .network(let msg) = $0 { return msg.contains("429") }
                    return false
                } ?? false

                if is429 && accountUsage[account.id] == nil && cachedUsage[account.id] == nil {
                    // No data at all — retry once after delay to build initial cache
                    log.info("[fetchUsage] 429 with no cache for \(account.email), retrying after 3s...")
                    try? await Task.sleep(for: .seconds(3))
                    if let retryUsage = try? await claudeService.getUsageLimits(accessToken: accessToken) {
                        accountUsage[account.id] = retryUsage
                        cachedUsage[account.id] = CachedUsageEntry(usage: retryUsage, fetchedAt: Date())
                        accountUsageErrors[account.id] = nil
                        log.info("[fetchUsage] Retry succeeded for \(account.email)")
                        continue
                    }
                }

                if is429 {
                    // Rate limited: keep any cached data (even stale) so weekly bar still shows
                    if accountUsage[account.id] == nil {
                        accountUsage[account.id] = cachedUsage[account.id]?.usage
                    }
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: true, message: "Rate limited")
                } else {
                    fallbackToCache(for: account.id)
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: error.localizedDescription)
                }
            }
        }
        saveUsageCache()
    }

    /// On error, preserve cached data in accountUsage — even stale cache is better than nil.
    /// The view will show a "stale" indicator when needed.
    private func fallbackToCache(for accountId: UUID) {
        if let cached = cachedUsage[accountId] {
            accountUsage[accountId] = cached.usage
        }
        // If no cache exists at all, leave accountUsage as-is (may already have data from previous fetch)
    }

    // MARK: - Diagnostics

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

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
    }

    private func loadUsageCache() {
        guard let data = UserDefaults.standard.data(forKey: usageCacheKey),
              let decoded = try? JSONDecoder().decode([UUID: CachedUsageEntry].self, from: data) else {
            log.info("[loadUsageCache] No saved usage cache found")
            return
        }
        cachedUsage = decoded
        log.info("[loadUsageCache] Loaded cache for \(decoded.count) accounts")
    }

    private func saveUsageCache() {
        if let data = try? JSONEncoder().encode(cachedUsage) {
            UserDefaults.standard.set(data, forKey: usageCacheKey)
            log.debug("[saveUsageCache] Saved cache for \(self.cachedUsage.count) accounts")
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
        } else if accounts.isEmpty {
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
