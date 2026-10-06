import SwiftUI

extension AppState {
    private struct SavedUsage: Codable {
        let usage: UsageAPIResponse
        let sampledAt: Date
    }

    func loadSavedUsage() {
        for account in accounts {
            guard let value = UserDefaults.standard.object(forKey: "savedUsage." + account.id.uuidString) else { continue }
            do {
                guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
                let saved = try JSONDecoder().decode(SavedUsage.self, from: data)
                accountUsage[account.id] = saved.usage
                accountUsageSampledAt[account.id] = saved.sampledAt
            } catch {
                accountUsageErrors[account.id] = UsageErrorState(
                    isExpired: false, isRateLimited: false,
                    message: String(localized: "Could not restore saved quota: \(error.localizedDescription)", bundle: L10n.bundle))
            }
        }
    }

    @discardableResult
    func refreshUsageCooldowns() async -> Bool {
        do {
            for account in accounts {
                usageNextRefreshAt[account.id] = try await UsageRequestLimiter.shared.nextAllowedDate(for: account.id)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshAccountUsage(_ account: Account) async {
        guard !isLoggingIn, !isSwitching,
              !refreshingUsageAccountIDs.contains(account.id),
              let current = accounts.first(where: { $0.id == account.id }) else { return }
        await performUsageRefresh(current)
    }

    func refreshNextAccountUsage() async {
        guard !isLoggingIn, !isSwitching else { return }
        let eligible = accounts.filter {
            automaticUsageAccountIDs.contains($0.id.uuidString)
                && !refreshingUsageAccountIDs.contains($0.id)
                && (usageNextRefreshAt[$0.id] ?? .distantPast) <= Date()
        }
        guard !eligible.isEmpty else { return }
        let target: Account
        if let active = eligible.first(where: \.isActive) {
            target = active
        } else {
            target = eligible[usageFetchCursor % eligible.count]
            usageFetchCursor += 1
        }
        await performUsageRefresh(target)
    }

    private func performUsageRefresh(_ account: Account) async {
        refreshingUsageAccountIDs.insert(account.id)
        defer { refreshingUsageAccountIDs.remove(account.id) }

        do {
            let tokenJSON = account.isActive
                ? keychain.readClaudeToken()
                : keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
            guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
                accountUsageErrors[account.id] = UsageErrorState(
                    isExpired: true, isRateLimited: false,
                    message: String(localized: "Stored credentials are unavailable. Re-authenticate this account to refresh quota.", bundle: L10n.bundle))
                return
            }

            let usage = try await claudeService.getUsageLimits(accessToken: accessToken, accountID: account.id)
            let sampledAt = Date()
            let data = try JSONEncoder().encode(SavedUsage(usage: usage, sampledAt: sampledAt))
            UserDefaults.standard.set(data, forKey: "savedUsage." + account.id.uuidString)
            accountUsage[account.id] = usage
            accountUsageSampledAt[account.id] = sampledAt
            accountUsageErrors[account.id] = nil
        } catch UsageRequestLimiter.RequestError.cooldown(let until) {
            usageNextRefreshAt[account.id] = until
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: false, isRateLimited: false,
                message: String(localized: "Quota refresh is cooling down. No request was sent.", bundle: L10n.bundle))
        } catch UsageRequestLimiter.RequestError.busy {
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: false, isRateLimited: false,
                message: String(localized: "This account's quota request is running. No request was sent.", bundle: L10n.bundle))
        } catch ClaudeService.UsageError.rateLimited {
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: false, isRateLimited: true,
                message: String(localized: "Rate limited. Waiting for the server's deadline; no automatic retry.", bundle: L10n.bundle))
        } catch ClaudeService.UsageError.expired {
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: true, isRateLimited: false,
                message: String(localized: "Session expired. Re-authenticate (↻) to fix.", bundle: L10n.bundle))
        } catch ClaudeService.UsageError.forbidden {
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: false, isRateLimited: false,
                message: String(localized: "Quota access was refused. No automatic retry.", bundle: L10n.bundle))
        } catch {
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: false, isRateLimited: false,
                message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
        }
        // Failed requests keep both the previous sample and its original timestamp.
        await refreshUsageCooldowns()
        updateWidgetData()
    }
}
