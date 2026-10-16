import Foundation

/// Reads the official CLI's existing cache; never launches a CLI or makes a request.
enum CLIUsageStore {
    struct Snapshot {
        let observedAt: Double
        let usage: UsageAPIResponse
    }

    private struct Configuration: Decodable {
        let oauthAccount: Identity?
        let cachedUsageUtilization: Cache?
    }
    private struct Identity: Decodable {
        let accountUuid: String
        let emailAddress: String
    }
    private struct Cache: Decodable {
        let accountUuid: String?
        let fetchedAtMs: Double
        let utilization: Utilization
    }
    private struct Utilization: Decodable {
        let usage: UsageAPIResponse
        let limits: [ScopedLimit]?

        init(from decoder: Decoder) throws {
            usage = try UsageAPIResponse(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            limits = try values.decodeIfPresent([ScopedLimit].self, forKey: .limits)
        }
        private enum CodingKeys: String, CodingKey { case limits }
    }
    private struct ScopedLimit: Decodable {
        let kind: String
        let percent: Double?
        let resets_at: String?
        let scope: Scope?
        struct Scope: Decodable {
            let model: Model?
            struct Model: Decodable { let display_name: String? }
        }
    }
    private enum CacheError: LocalizedError {
        case identityChanged, differentAccount, invalidData
        var errorDescription: String? {
            switch self {
            case .identityChanged:
                String(localized: "The current CLI account changed. Refresh the account list before syncing quota.", bundle: L10n.bundle)
            case .differentAccount:
                String(localized: "The local quota cache belongs to another account. Waiting for the current CLI account to update it.", bundle: L10n.bundle)
            case .invalidData:
                String(localized: "The local CLI quota cache contains invalid data.", bundle: L10n.bundle)
            }
        }
    }

    static func read(accountUuid: String, email: String,
                     configurationURL: URL = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".claude.json")) throws -> Snapshot? {
        // Identity and quota come from one read, so a file replacement cannot mix accounts.
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configurationURL))
        guard let expectedID = UUID(uuidString: accountUuid),
              let identity = config.oauthAccount,
              UUID(uuidString: identity.accountUuid) == expectedID,
              identity.emailAddress == email else { throw CacheError.identityChanged }
        guard let cache = config.cachedUsageUtilization else { return nil }
        guard let cachedID = cache.accountUuid.flatMap(UUID.init(uuidString:)),
              cachedID == expectedID else { throw CacheError.differentAccount }
        let observedAt = cache.fetchedAtMs / 1000
        guard observedAt.isFinite, observedAt > 0,
              observedAt <= Date().timeIntervalSince1970 + 60 else { throw CacheError.invalidData }

        var usage = cache.utilization.usage
        // Fable's documented-in-the-installed-CLI shape is a scoped weekly limit.
        // Never reinterpret legacy opaque field names or another model's quota.
        let fable = (cache.utilization.limits ?? []).filter {
            $0.kind == "weekly_scoped"
                && ["fable", "fable 5", "fable 5.1"].contains($0.scope?.model?.display_name?.lowercased() ?? "")
        }
        guard fable.count <= 1 else { throw CacheError.invalidData }
        usage.sevenDayFable = nil
        if let limit = fable.first {
            guard let percent = limit.percent else { throw CacheError.invalidData }
            usage.sevenDayFable = UsageWindow(utilization: percent, resetsAt: limit.resets_at)
        }
        let windows = [usage.fiveHour, usage.sevenDay, usage.sevenDayOpus, usage.sevenDaySonnet,
                       usage.sevenDayOauthApps, usage.sevenDayCowork, usage.iguanaNecktie, usage.sevenDayFable].compactMap { $0 }
        guard !windows.isEmpty else { throw CacheError.invalidData }
        for window in windows {
            if let percent = window.utilization {
                guard percent.isFinite, (0...100).contains(percent) else { throw CacheError.invalidData }
            }
            if window.resetsAt != nil {
                guard let reset = window.resetsAtDate,
                      reset.timeIntervalSince1970 > 0, reset <= Date.distantFuture else { throw CacheError.invalidData }
            }
        }
        return Snapshot(observedAt: observedAt, usage: usage)
    }
}
