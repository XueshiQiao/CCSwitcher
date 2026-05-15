import Foundation

/// Provides today's coding activity stats from Claude Code session JSONL files.
/// All parsing is done by `SessionParseCacheV2`; this is a thin facade.
final class ActivityParser: Sendable {
    static let shared = ActivityParser()
    private init() {}

    /// Today's stats aggregated from the in-memory parse cache.
    /// Caller must ensure `SessionParseCacheV2.shared.refreshFromFilesystem()`
    /// has been awaited at least once this cycle.
    func getTodayStats() async -> ActivityStats {
        return await SessionParseCacheV2.shared.activityStatsToday()
    }
}
