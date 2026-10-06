import Foundation

/// One gate for manual refresh, background polling, and auto-switch verification.
actor UsageRequestLimiter {
    static let shared = UsageRequestLimiter()

    enum RequestError: Error {
        case busy
        case cooldown(Date)
    }

    private let defaults = UserDefaults.standard
    private let accountKeyPrefix = "usageRequestAccountDeadline."
    private var requestingAccountIDs: Set<UUID> = []

    private init() {}

    /// An account's waiting period never blocks another account.
    func nextAllowedDate(for accountID: UUID) throws -> Date? {
        try deadline(forKey: accountKeyPrefix + accountID.uuidString)
    }

    private func deadline(forKey key: String) throws -> Date? {
        guard let value = defaults.object(forKey: key) else { return nil }
        guard let timestamp = value as? Double, timestamp.isFinite,
              timestamp >= 0, timestamp <= Date.distantFuture.timeIntervalSince1970 else {
            throw ClaudeService.UsageError.network("Invalid saved usage request deadline: \(key)")
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    func getUsageLimits(accessToken: String, accountID: UUID) async throws -> UsageAPIResponse {
        guard !requestingAccountIDs.contains(accountID) else { throw RequestError.busy }
        let now = Date()
        if let next = try nextAllowedDate(for: accountID), next > now {
            throw RequestError.cooldown(next)
        }
        guard !accessToken.isEmpty else {
            throw ClaudeService.UsageError.network("Missing access token for usage refresh")
        }
        try Task.checkCancellation()
        requestingAccountIDs.insert(accountID)
        defer { requestingAccountIDs.remove(accountID) }

        // Record attempts before the suspension: failures and restarts cannot
        // turn the refresh button into a burst of requests.
        let accountKey = accountKeyPrefix + accountID.uuidString
        defaults.set(now.addingTimeInterval(15 * 60).timeIntervalSince1970, forKey: accountKey)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClaudeService.UsageError.network("Usage endpoint returned a non-HTTP response")
        }
        switch response.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(UsageAPIResponse.self, from: data)
            } catch {
                throw ClaudeService.UsageError.decode(error.localizedDescription)
            }
        case 401:
            throw ClaudeService.UsageError.expired
        case 403:
            throw ClaudeService.UsageError.forbidden("HTTP 403")
        case 429:
            let receivedAt = Date()
            let retryAfter = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: receivedAt)
            let next = receivedAt.addingTimeInterval(max(15 * 60, retryAfter ?? 0))
            defaults.set(next.timeIntervalSince1970, forKey: accountKey)
            throw ClaudeService.UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw ClaudeService.UsageError.network("HTTP \(response.statusCode)")
        }
    }

    private static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard seconds.isFinite, seconds >= 0 else { return nil }
            // Saturate only at Foundation's representable calendar ceiling,
            // never at an arbitrary rate-limit cap such as one hour.
            return min(seconds, Date.distantFuture.timeIntervalSince(now))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, min(date, .distantFuture).timeIntervalSince(now))
    }
}
