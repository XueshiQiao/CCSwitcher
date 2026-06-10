import Foundation

/// Provides cost summaries from Claude Code session JSONL files.
/// All actual parsing is done by `SessionParseCacheV2`; this is a thin facade.
final class CostParser: Sendable {
    static let shared = CostParser()
    private init() {}

    /// Compute cost summary from the in-memory parse cache.
    /// Caller must ensure `SessionParseCacheV2.shared.refreshFromFilesystem()`
    /// has been awaited at least once this cycle.
    func getCostSummary() async -> CostSummary {
        return await SessionParseCacheV2.shared.costSummary()
    }

    // MARK: - Helpers

    /// "claude-opus-4-6" → "Opus", "claude-fable-5" → "Fable"
    static func shortModelName(_ model: String) -> String {
        if model.contains("fable") { return "Fable" }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}
