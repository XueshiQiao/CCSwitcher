import Foundation

// MARK: - Token Cost Models

/// Per-model pricing in USD per 1M tokens.
struct ModelPricing {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    // Official pricing from platform.claude.com/docs/en/about-claude/pricing (synced 2026-05).
    // Cache write column = 5-minute tier (1.25x base input). Claude Code's JSONL records
    // a single `cache_creation_input_tokens` counter that does not distinguish 5m vs 1h,
    // so we apply the 5m rate (the common case for prompt caching).
    static let pricing: [String: ModelPricing] = [
        // Opus
        "claude-opus-4-7": ModelPricing(input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-6": ModelPricing(input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-5": ModelPricing(input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-1": ModelPricing(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-opus-4": ModelPricing(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-opus-3": ModelPricing(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50),
        // Sonnet
        "claude-sonnet-4-6": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-4-5": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-4": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-3-7": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        // Haiku
        "claude-haiku-4-5": ModelPricing(input: 1.0, output: 5.0, cacheWrite: 1.25, cacheRead: 0.10),
        "claude-haiku-3-5": ModelPricing(input: 0.80, output: 4.0, cacheWrite: 1.0, cacheRead: 0.08),
        "claude-haiku-3": ModelPricing(input: 0.25, output: 1.25, cacheWrite: 0.30, cacheRead: 0.03),
    ]

    /// Look up pricing by model ID. Exact match first; then longest-base prefix match so
    /// e.g. `claude-opus-4-7-20260115` resolves to `claude-opus-4-7`, not the shorter
    /// `claude-opus-4` (which would charge 3x the correct rate).
    static func forModel(_ model: String) -> ModelPricing? {
        if let exact = pricing[model] { return exact }
        let candidates: [(base: String, value: ModelPricing)] = pricing.map { key, value in
            let parts = key.split(separator: "-")
            let baseParts = parts.prefix(while: { !$0.allSatisfy(\.isNumber) || $0.count < 8 })
            let base = baseParts.map(String.init).joined(separator: "-")
            return (base, value)
        }
        // Sort by base length descending so the most specific match wins.
        // Require an exact match or a hyphen boundary so `claude-opus-4-7` does not
        // spuriously match a hypothetical `claude-opus-4-70` model.
        for candidate in candidates.sorted(by: { $0.base.count > $1.base.count }) {
            if model == candidate.base || model.hasPrefix(candidate.base + "-") {
                return candidate.value
            }
        }
        return nil
    }
}

/// Token usage from a single API call.
struct TokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let model: String
    let timestamp: Date
    let sessionFile: String

    var cost: Double {
        guard let pricing = ModelPricing.forModel(model) else { return 0 }
        return Double(inputTokens) / 1_000_000 * pricing.input
            + Double(outputTokens) / 1_000_000 * pricing.output
            + Double(cacheWriteTokens) / 1_000_000 * pricing.cacheWrite
            + Double(cacheReadTokens) / 1_000_000 * pricing.cacheRead
    }
}

/// Aggregated cost for a single day.
struct DailyCost: Identifiable {
    let date: String // "yyyy-MM-dd"
    let totalCost: Double
    let modelBreakdown: [String: Double] // model -> cost
    let sessionCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int

    var id: String { date }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }
}

/// Overall cost summary.
struct CostSummary {
    let todayCost: Double
    let dailyCosts: [DailyCost]

    var totalCost: Double {
        dailyCosts.reduce(0) { $0 + $1.totalCost }
    }

    static let empty = CostSummary(todayCost: 0, dailyCosts: [])
}
