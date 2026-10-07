import SwiftUI

extension AppState {
    private struct SavedUsage: Codable {
        let usage: UsageAPIResponse
        let sampledAt: Date
        let fromCLI: Bool?
        let source: String?
    }

    func loadSavedUsage() {
        for account in accounts {
            guard let value = UserDefaults.standard.object(forKey: "savedUsage." + account.id.uuidString) else { continue }
            do {
                guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
                let saved = try JSONDecoder().decode(SavedUsage.self, from: data)
                accountUsage[account.id] = saved.usage
                accountUsageSampledAt[account.id] = saved.sampledAt
                if saved.fromCLI == true { cliUsageAccountIDs.insert(account.id) }
                if saved.source == "officialCLI" { officialCLIUsageAccountIDs.insert(account.id) }
            } catch {
                accountUsageErrors[account.id] = UsageErrorState(
                    isExpired: false, isRateLimited: false,
                    message: String(localized: "Could not restore saved quota: \(error.localizedDescription)", bundle: L10n.bundle))
            }
        }
    }

    func cliUsageCheckAvailableAt(_ account: Account) -> Date? {
        guard let started = UserDefaults.standard.object(forKey: "cliUsageCheckStarted." + account.id.uuidString) as? Date else { return nil }
        let available = started.addingTimeInterval(15 * 60)
        return available > Date() ? available : nil
    }

    func openCLIUsageSession(_ account: Account) {
        guard !isLoggingIn, !isSwitching, !isLoading, !isRefreshing, refreshingUsageAccountIDs.isEmpty,
              activeAccount?.id == account.id,
              let current = visibleAccounts.first(where: { $0.id == account.id }),
              cliUsageCheckAvailableAt(current) == nil else { return }
        guard let identity = keychain.readOAuthAccount(),
              let accountUuid = identity["accountUuid"]?.value as? String, UUID(uuidString: accountUuid) != nil,
              let email = identity["emailAddress"]?.value as? String, email == current.email else {
            errorMessage = String(localized: "Local account identity unavailable. No quota request was sent.", bundle: L10n.bundle)
            return
        }
        do {
            try CLIUsageSession.open(claudePath: claudeService.claudePath, accountUuid: accountUuid, email: email)
            UserDefaults.standard.set(Date(), forKey: "cliUsageCheckStarted." + current.id.uuidString)
            errorMessage = nil
            // Opening Terminal is not a completed quota fetch; keep the real sample timestamp.
            objectWillChange.send()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAccountUsage(_ account: Account) async {
        guard !isLoggingIn, !isSwitching, !isLoading, !isRefreshing, refreshingUsageAccountIDs.isEmpty,
              activeAccount?.id == account.id,
              let current = visibleAccounts.first(where: { $0.id == account.id }) else { return }
        importCLIUsage(current)
        updateWidgetData()
    }

    /// Only the current account may import local data; inactive accounts retain history.
    func refreshLocalUsage() {
        guard !isLoggingIn, !isSwitching, !isLoading, !isRefreshing, refreshingUsageAccountIDs.isEmpty,
              let account = visibleAccounts.first(where: { $0.id == activeAccount?.id }),
              automaticUsageAccountIDs.contains(account.id.uuidString) else { return }
        let previous = accountUsageSampledAt
        importCLIUsage(account)
        if accountUsageSampledAt != previous { updateWidgetData() }
    }

    private func importCLIUsage(_ account: Account) {
        do {
            guard let identity = keychain.readOAuthAccount(),
                  let accountUuid = identity["accountUuid"]?.value as? String,
                  let email = identity["emailAddress"]?.value as? String,
                  email == account.email else {
                accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false,
                    message: String(localized: "Local account identity unavailable. No quota request was sent.", bundle: L10n.bundle))
                return
            }
            guard let snapshot = try CLIUsageStore.read(accountUuid: accountUuid, email: email) else {
                accountUsageErrors[account.id] = nil
                return
            }
            let observedAt = Date(timeIntervalSince1970: snapshot.observedAt)
            // Re-reading a file never makes a historical record look newly sampled.
            // Legacy bridge timestamps described CLI output observation, not the official sample.
            if officialCLIUsageAccountIDs.contains(account.id),
               let previous = accountUsageSampledAt[account.id], observedAt <= previous {
                accountUsageErrors[account.id] = nil
                return
            }
            let usage = snapshot.usage
            let data = try JSONEncoder().encode(SavedUsage(usage: usage, sampledAt: observedAt, fromCLI: true, source: "officialCLI"))
            UserDefaults.standard.set(data, forKey: "savedUsage." + account.id.uuidString)
            accountUsage[account.id] = usage
            accountUsageSampledAt[account.id] = observedAt
            cliUsageAccountIDs.insert(account.id)
            officialCLIUsageAccountIDs.insert(account.id)
            accountUsageErrors[account.id] = nil
        } catch {
            accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false,
                message: String(localized: "Could not read local CLI quota: \(error.localizedDescription)", bundle: L10n.bundle))
        }
    }
}
