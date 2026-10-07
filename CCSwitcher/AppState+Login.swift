import SwiftUI

private let log = FileLog("AppState")

extension AppState {
    func cancelLogin() {
        guard canCancelLogin, let loginTask else { return }
        isCancellingLogin = true
        canCancelLogin = false
        loginURL = nil
        loginTask.cancel()
    }

    private func performBrowserLogin() async throws {
        loginURL = nil
        let task = Task {
            try await claudeService.login { [weak self] url in
                await self?.setLoginURL(url)
            }
        }
        loginTask = task
        canCancelLogin = true
        defer { loginTask = nil; canCancelLogin = false; loginURL = nil }
        try await task.value
        if task.isCancelled { throw CancellationError() }
    }

    private func setLoginURL(_ url: URL) {
        guard isLoggingIn, canCancelLogin, !isCancellingLogin else { return }
        loginURL = url
    }

    private func reconcileCancelledLogin() {
        // The browser may have finished just before cancellation. Read local identity;
        // never restore credentials or capture them under the previous account's ID.
        suppressAutomaticAccountDiscovery = true
        let email = keychain.readOAuthAccount()?["emailAddress"]?.value as? String
        for i in accounts.indices {
            accounts[i].isActive = email != nil && accounts[i].email == email
        }
        activeAccount = accounts.first(where: \.isActive)
        saveAccounts(refreshWidget: true)
        errorMessage = String(localized: "Login cancelled. If browser authorization already finished, use Add Current Account to keep that login.", bundle: L10n.bundle)
    }

    func loginNewAccount() async {
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            return
        }
        // One credential mutation at a time (same guard as switchTo). A login
        // entering while a switch is suspended mid-swap would back up the
        // WRONG live credential under the old active account's id — quietly
        // destroying that account's usable backup. Also blocks double-clicks.
        guard !isSwitching, !isLoggingIn, !isRefreshing, refreshingUsageAccountIDs.isEmpty else {
            log.warning("[loginNewAccount] Skipped: a switch or another login is in progress")
            return
        }

        isLoggingIn = true
        defer { isLoggingIn = false; isCancellingLogin = false }
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
            try await performBrowserLogin()
            suppressAutomaticAccountDiscovery = false
            log.info("[loginNewAccount] Step 2: Login process completed")

            // 3. Read the new identity from ~/.claude.json
            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                return
            }
            guard let email = status.email else {
                errorMessage = shadowedIdentityMessage(status)
                log.error("[loginNewAccount] Step 3: CLI reports authMethod=\(status.authMethod ?? "nil") without an account identity")
                return
            }
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            // 4. Check for duplicate — if exists, refresh its backup and make it
            // the active account. The login DID change what the CLI is
            // authenticated as; returning without updating our model left the
            // menu bar and switcher presenting an account the CLI was no longer
            // using. The capture CAN also fail (e.g. the backup store refuses
            // writes while unreadable); claiming "credentials refreshed" then
            // would leave a stale backup behind an explicit success message.
            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup and marking it active")
                let captured = claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString)
                for i in accounts.indices {
                    accounts[i].isActive = (i == existing)
                }
                accounts[existing].lastUsed = Date()
                if accounts[existing].recycledAt != nil {
                    automaticUsageAccountIDs.remove(accounts[existing].id.uuidString)
                }
                accounts[existing].recycledAt = nil
                activeAccount = accounts[existing]
                // A login is a deliberate account choice; grant it the same
                // auto-switch grace period a manual switch gets.
                lastAutoSwitchAt = Date()
                saveAccounts(refreshWidget: true)
                if captured {
                    errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                } else {
                    log.error("[loginNewAccount] Step 4: Backup capture FAILED for existing account")
                    errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                }
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
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                return
            }

            // 6. Mark new account as active
            for i in accounts.indices {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            // A login is a deliberate account choice; grant it the same
            // auto-switch grace period a manual switch gets.
            lastAutoSwitchAt = Date()
            saveAccounts()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            updateWidgetData()
            log.info("[loginNewAccount] ===== Login completed =====")
        } catch is CancellationError {
            reconcileCancelledLogin()
        } catch {
            errorMessage = error.localizedDescription
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        guard let account = visibleAccounts.first(where: { $0.id == account.id }) else { return }
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }
        // One credential mutation at a time — see loginNewAccount for why a
        // login during a suspended switch destroys a backup.
        guard !isSwitching, !isLoggingIn, !isRefreshing, refreshingUsageAccountIDs.isEmpty else {
            log.warning("[reauth] Skipped: a switch or another login is in progress")
            return
        }

        isLoggingIn = true
        defer { isLoggingIn = false; isCancellingLogin = false }
        errorMessage = nil

        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                _ = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
            }

            // 2. Run login
            log.info("[reauth] Running `claude auth login`...")
            try await performBrowserLogin()
            suppressAutomaticAccountDiscovery = false

            // 3. Verify the login result matches the target account
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                return
            }
            guard let email = status.email else {
                errorMessage = shadowedIdentityMessage(status)
                log.error("[reauth] CLI reports authMethod=\(status.authMethod ?? "nil") without an account identity")
                return
            }

            guard email == account.email else {
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                return
            }

            // 4. Capture the fresh token
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            log.info("[reauth] Token capture result: \(captured)")

            // 5. Update account metadata. Done even when the capture failed —
            // the CLI really is on this account now — but a failed capture must
            // be surfaced, not folded into "completed": the stored backup is
            // still the OLD credential, so a later switch away and back would
            // fail while the UI claimed everything was refreshed.
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                // A re-authentication is a deliberate account choice; grant it
                // the same auto-switch grace period a manual switch gets.
                lastAutoSwitchAt = Date()
                saveAccounts()
            }

            updateWidgetData()
            if captured {
                log.info("[reauth] ===== Re-authentication completed =====")
            } else {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[reauth] ===== Re-authentication finished, but the backup capture FAILED =====")
            }
        } catch is CancellationError {
            reconcileCancelledLogin()
        } catch {
            errorMessage = error.localizedDescription
            log.error("[reauth] Error: \(error.localizedDescription)")
        }
    }

}
