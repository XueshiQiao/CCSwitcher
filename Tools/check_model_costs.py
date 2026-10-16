#!/usr/bin/env python3
"""Offline production aggregation check; no session files, CLI or network are used.

Fails if model versions are merged, duplicate requests inflate usage, unknown
prices become zero, per-request pricing changes, or cache rates average days.
"""
from pathlib import Path
import subprocess
import tempfile

HARNESS = r'''
import Foundation
// Log output is the only mocked boundary. Pricing math and aggregation are real.
struct FileLog: Sendable {
    init(_ name: String) {}
    func info(_ value: String) {}
    func debug(_ value: String) {}
    func warning(_ value: String) {}
    func error(_ value: String) {}
}
@main struct Check {
    static func main() {
        let a = "claude-opus-4-6", b = "claude-opus-4-7", unknown = "claude-fable-fixture"
        let now = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let price = LiteLLMModelPricing(inputPerToken: 0.000001, outputPerToken: 0.000002,
            cacheCreatePerToken: 0.000003, cacheCreate1hPerToken: 0.000006,
            cacheReadPerToken: 0.0000001, inputAbove200k: nil, outputAbove200k: nil,
            cacheCreateAbove200k: nil, cacheReadAbove200k: nil, fastMultiplier: 2)
        let prices: [String: LiteLLMModelPricing?] = [a: price, b: price]
        func row(_ model: String, _ hash: String?, _ day: String = "2026-10-08",
                 input: Int = 0, output: Int = 0, cw: Int = 0, cw1h: Int = 0,
                 cr: Int = 0, fast: Bool = false) -> CachedEntryV2 {
            CachedEntryV2(hash: hash, date: day, hour: 12, model: model, speed: fast ? "fast" : nil,
                          input: input, output: output, cw: cw, cw1h: cw1h, cr: cr,
                          costUSDRow: 999, tools: [:], linesWritten: 0)
        }
        func file(_ entries: [CachedEntryV2], _ session: String) -> CachedFileV2 {
            CachedFileV2(mtimeUnix: 1, earliestTimestampUnix: 1, project: "fixture", sessionId: session,
                         isSidechain: false, entries: entries, activityByDate: [:])
        }
        func near(_ actual: Double?, _ expected: Double) {
            precondition(actual != nil && abs(actual! - expected) < 0.000000001,
                         "Expected \(expected), got \(String(describing: actual))")
        }
        let files = [
            "one": file([row(a, "same", input: 20, output: 5, cw: 10, cw1h: 4, cr: 70),
                         row(a, nil, output: 1), row(b, "new-version", input: 1, output: 2, fast: true),
                         row(unknown, "unpriced", input: 100, output: 9),
                         row("<synthetic>", "synthetic")], "one"),
            "two": file([row(a, "same", input: 20, output: 10, cw: 10, cw1h: 4, cr: 70),
                         row(a, nil, output: 1),
                         row(a, "yesterday", "2026-10-07", input: 900, output: 1000)], "two")
        ]
        let summary = SessionParseCacheV2.aggregateCosts(files: files, prices: prices, now: now)
        let today = summary.period(days: 1, ending: now, calendar: calendar)
        precondition(Set(today.models.map(\.modelID)) == Set([a, b, unknown]))
        precondition(today.requestCount == 5, "Duplicate hash or nil-hash rows were counted incorrectly")
        let first = today.models.first { $0.modelID == a }!
        precondition(first.requestCount == 3 && first.outputTokens == 12 && first.cacheWriteTokens == 10)
        precondition(first.totalTokens == 112, "One-hour cache writes were double-counted")
        near(first.cost, 0.000093) // 1h/5m split is charged per request; duplicate loser is excluded.
        near(today.models.first { $0.modelID == b }!.cost, 0.000010)
        precondition(today.models.first { $0.modelID == unknown }!.cost == nil)
        precondition(today.hasUnpricedUsage)
        near(today.knownCost, 0.000103)
        near(first.cacheHitRate, 70)
        near(today.cacheHitRate, 70.0 / 201.0 * 100)
        let week = summary.period(days: 7, ending: now, calendar: calendar)
        near(week.models.first { $0.modelID == a }!.cacheHitRate, 7)
        near(week.models.first { $0.modelID == a }!.cost, 0.002993)

        let zero = ModelCost(modelID: a, inputTokens: 0, outputTokens: 500,
                             cacheWriteTokens: 0, cacheReadTokens: 0, requestCount: 1, cost: 1)
        precondition(zero.cacheHitRate == nil, "Output tokens must not enter the cache denominator")
        let empty = CostSummary.empty.period(days: 1, ending: now, calendar: calendar)
        precondition(empty.cacheHitRate == nil && empty.models.isEmpty && !empty.hasUnpricedUsage)

        let dates = ["2026-10-08", "2026-10-02", "2026-10-01", "2026-09-09", "2026-09-08", "2026-10-09"]
        let bounds = SessionParseCacheV2.aggregateCosts(
            files: ["days": file(dates.map { row(a, $0, $0, input: 1) }, "days")], prices: prices, now: now)
        for (days, count) in [(1, 1), (7, 2), (30, 4)] {
            let period = bounds.period(days: days, ending: now, calendar: calendar)
            precondition(period.requestCount == count && period.dailyCosts.count == count,
                         "Period includes the wrong local day or future data")
        }
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        precondition(bounds.period(days: 30, ending: now, calendar: buddhist).requestCount == 4,
                     "User calendar changed the Gregorian cache date keys")
        let tiered = LiteLLMModelPricing(inputPerToken: 0.000001, outputPerToken: 0.000002,
            cacheCreatePerToken: 0.000003, cacheCreate1hPerToken: 0.000006,
            cacheReadPerToken: 0.0000001, inputAbove200k: 0.000002, outputAbove200k: nil,
            cacheCreateAbove200k: nil, cacheReadAbove200k: nil, fastMultiplier: nil)
        let tierSummary = SessionParseCacheV2.aggregateCosts(files: ["tier": file([
            row(a, "large", input: 200001), row(a, "small-one", input: 150001),
            row(a, "small-two", input: 150001)], "tier")], prices: [a: tiered], now: now)
        near(tierSummary.period(days: 1, ending: now, calendar: calendar).knownCost, 0.500004)
        print("PASS: exact models, global max-output dedup, nil IDs, 1h/fast pricing, unknown prices, weighted cache ratios and calendar periods")
    }
}
'''


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="model-costs-") as temporary:
        work = Path(temporary)
        harness = work / "Check.swift"
        harness.write_text(HARNESS)
        binary = work / "check"
        sources = ["Models/CostData.swift", "Models/ActivityData.swift", "Services/CostParser.swift",
                   "Services/PricingService.swift", "Services/SessionParseCacheV2.swift"]
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(work / "modules"),
                        *[str(root / "CCSwitcher" / name) for name in sources], str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
