import Foundation

/// Data shared between the main app and widget via direct file in the widget's sandbox container.
///
/// The main app (non-sandboxed) writes a JSON file into the widget extension's container directory.
/// The widget (sandboxed) reads from its own Application Support, which maps to the same path.
struct WidgetAccountData: Codable, Sendable {
    let email: String          // pre-obfuscated
    let displayName: String    // pre-obfuscated
    let subscriptionType: String?
    let isActive: Bool
    let sessionUtilization: Double?
    let sessionResetTime: String?
    let weeklyUtilization: Double?
    let weeklyResetTime: String?
    /// Display name of the model the scoped weekly limit applies to (e.g.
    /// "Fable"), or nil when the account has no model-scoped weekly limit.
    /// Optional — a payload written by an older build simply decodes to nil.
    let modelWeeklyLabel: String?
    let modelWeeklyUtilization: Double?
    let modelWeeklyResetTime: String?
    let extraUsageEnabled: Bool?
    let hasError: Bool
    let errorMessage: String?
}

struct WidgetData: Codable, Sendable {
    let accounts: [WidgetAccountData]
    let todayCost: Double
    let conversationTurns: Int
    let activeCodingTime: String
    let linesWritten: Int
    let modelUsage: [String: Int]
    let lastUpdated: Date

    // Team-ID-prefixed App Group. macOS Sequoia (15+) prompts for App
    // Management on `group.<bundle-id>` style identifiers; the
    // `<TEAMID>.<bundle-id>` form is auto-authorized for Developer-ID-signed
    // apps without a provisioning profile and avoids the prompt entirely.
    private static let appGroupID = "584KQTRF3B.me.xueshi.ccswitcher"
    private static let fileName = "widget-data.json"

    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Load from the shared App Group container.
    static func load() -> WidgetData? {
        guard let containerURL = sharedContainerURL else { return nil }
        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    /// Save to the shared App Group container.
    ///
    /// Blocking. The FIRST write after launch can sit in `open()` for tens of
    /// seconds while `containermanagerd` materializes the group container
    /// (later writes are sub-millisecond), so never call this from the main
    /// actor — use `saveInBackground()`.
    func save() {
        guard let containerURL = Self.sharedContainerURL else { return }
        let fileURL = containerURL.appendingPathComponent(Self.fileName)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Serializes widget writes off the caller's actor.
///
/// `WidgetData.save()` ends in an atomic write inside the App Group container.
/// That write is normally instant, but the first one after a cold launch has
/// been measured blocking in `open()` for 11–62s while the container is
/// materialized. Running it on the `@MainActor` froze the menu bar for exactly
/// that long. The actor also stops two overlapping refreshes from interleaving
/// writes.
private actor WidgetDataWriter {
    static let shared = WidgetDataWriter()

    private var lastWritten: Date = .distantPast

    func write(_ data: WidgetData) {
        // A cold write can stay in flight for a minute, long enough for a
        // later refresh to queue behind it. Drop the stale snapshot rather
        // than letting it land on top of newer numbers.
        guard data.lastUpdated >= lastWritten else { return }
        lastWritten = data.lastUpdated
        data.save()
    }
}

extension WidgetData {
    /// Persist without blocking the caller's actor. See `WidgetDataWriter`.
    func saveInBackground() async {
        await WidgetDataWriter.shared.write(self)
    }
}
