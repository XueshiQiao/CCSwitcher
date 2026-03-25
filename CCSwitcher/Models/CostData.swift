import Foundation

// MARK: - Token Cost Models

/// Per-model pricing in USD per 1M tokens.
struct ModelPricing {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    // Official pricing from platform.claude.com/docs/en/about-claude/pricing
    // Cache write = 5-minute tier (1.25x base input). Cache read = 0.1x base input.
    static let pricing: [String: ModelPricing] = [
        "claude-opus-4-6": ModelPricing(input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-5": ModelPricing(input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-1": ModelPricing(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-opus-4": ModelPricing(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-sonnet-4-6": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-4-5-20250514": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-4": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-haiku-4-5": ModelPricing(input: 1.0, output: 5.0, cacheWrite: 1.25, cacheRead: 0.10),
        "claude-haiku-3-5": ModelPricing(input: 0.80, output: 4.0, cacheWrite: 1.0, cacheRead: 0.08),
    ]

    static func forModel(_ model: String) -> ModelPricing? {
        if let exact = pricing[model] { return exact }
        // Prefix match for versioned model names
        for (key, value) in pricing {
            let parts = key.split(separator: "-")
            let baseParts = parts.prefix(while: { !$0.allSatisfy(\.isNumber) || $0.count < 8 })
            let base = baseParts.map(String.init).joined(separator: "-")
            if model.hasPrefix(base) { return value }
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
