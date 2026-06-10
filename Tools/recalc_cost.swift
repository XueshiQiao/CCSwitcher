#!/usr/bin/env swift
// recalc_cost.swift — Standalone re-parser that aggregates Claude Code
// JSONL session logs into per-day × per-model × per-token-type totals,
// for the sole purpose of cross-checking against `ccusage daily`.
//
// Behavior is deliberately mirrored from ccusage 20.0.9 (the published
// bundle, NOT git HEAD — the two differ):
//   - Recursive walk of ~/.claude/projects/ (includes subagents/)
//   - Files visited in earliest-timestamp ascending order
//   - Dedup key: "{message.id}:{requestId}", global across files, first-wins
//   - Pricing: LiteLLM model_prices_and_context_window.json (live fetch)
//   - 200k-token tier supported; "fast" speed multiplier supported
//   - 1-hour cache-write tokens (cache_creation.ephemeral_1h_input_tokens)
//     billed at cache_creation_input_token_cost_above_1hr (added in ccusage 19+)
//   - Date bucket = local-time yyyy-MM-dd of `timestamp`
//
// Usage:
//   swift Tools/recalc_cost.swift            # last 5 days, table output
//   swift Tools/recalc_cost.swift --json     # machine-readable JSON
//   swift Tools/recalc_cost.swift --days N   # custom range

import Foundation

// MARK: - Args

struct Args {
    var days: Int = 5
    var jsonOutput: Bool = false
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--json": a.jsonOutput = true
        case "--days":
            if let v = it.next(), let n = Int(v) { a.days = n }
        default: break
        }
    }
    return a
}

let args = parseArgs()

// MARK: - LiteLLM pricing

let pricingURL = URL(string:
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
)!
let pricingCachePath = "/tmp/litellm-pricing.json"

struct ModelPricing {
    let inputPerToken: Double
    let outputPerToken: Double
    let cacheCreatePerToken: Double
    let cacheCreate1hPerToken: Double?   // cache_creation_input_token_cost_above_1hr (1-hour TTL write rate)
    let cacheReadPerToken: Double
    let inputAbove200k: Double?
    let outputAbove200k: Double?
    let cacheCreateAbove200k: Double?
    let cacheReadAbove200k: Double?
    let fastMultiplier: Double?
}

func fetchPricing() -> [String: ModelPricing] {
    let fm = FileManager.default
    var data: Data
    if fm.fileExists(atPath: pricingCachePath),
       let attrs = try? fm.attributesOfItem(atPath: pricingCachePath),
       let mtime = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince(mtime) < 3600,
       let cached = try? Data(contentsOf: URL(fileURLWithPath: pricingCachePath)) {
        data = cached
        FileHandle.standardError.write("[pricing] using cache (age <1h): \(pricingCachePath)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("[pricing] fetching from LiteLLM...\n".data(using: .utf8)!)
        let sem = DispatchSemaphore(value: 0)
        var fetched: Data?
        var err: Error?
        URLSession.shared.dataTask(with: pricingURL) { d, _, e in
            fetched = d; err = e; sem.signal()
        }.resume()
        sem.wait()
        guard let d = fetched else {
            FileHandle.standardError.write("[pricing] fetch failed: \(err?.localizedDescription ?? "unknown")\n".data(using: .utf8)!)
            exit(1)
        }
        try? d.write(to: URL(fileURLWithPath: pricingCachePath))
        data = d
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        FileHandle.standardError.write("[pricing] failed to parse JSON\n".data(using: .utf8)!)
        exit(1)
    }
    var out: [String: ModelPricing] = [:]
    for (name, value) in json {
        guard let dict = value as? [String: Any] else { continue }
        let input = (dict["input_cost_per_token"] as? Double) ?? 0
        let output = (dict["output_cost_per_token"] as? Double) ?? 0
        let cw = (dict["cache_creation_input_token_cost"] as? Double) ?? 0
        // 1-hour cache writes bill at 2x base input (Anthropic's documented rule;
        // the 5-minute default is 1.25x). LiteLLM exposes this as *_above_1hr for
        // some models but omits it for others (e.g. claude-sonnet-4-6), while
        // ccusage applies the 2x-input rule universally. Fall back to 2x input so
        // a missing field doesn't silently drop the 1h premium.
        let cw1h = (dict["cache_creation_input_token_cost_above_1hr"] as? Double) ?? (input > 0 ? input * 2 : nil)
        let cr = (dict["cache_read_input_token_cost"] as? Double) ?? 0
        // Skip rows that have no pricing at all (LiteLLM has metadata-only rows)
        if input == 0 && output == 0 && cw == 0 && cr == 0 { continue }
        let inputHi = dict["input_cost_per_token_above_200k_tokens"] as? Double
        let outputHi = dict["output_cost_per_token_above_200k_tokens"] as? Double
        let cwHi = dict["cache_creation_input_token_cost_above_200k_tokens"] as? Double
        let crHi = dict["cache_read_input_token_cost_above_200k_tokens"] as? Double
        let fast: Double? = {
            if let prov = dict["provider_specific_entry"] as? [String: Any] {
                return prov["fast"] as? Double
            }
            return nil
        }()
        out[name] = ModelPricing(
            inputPerToken: input, outputPerToken: output,
            cacheCreatePerToken: cw, cacheCreate1hPerToken: cw1h, cacheReadPerToken: cr,
            inputAbove200k: inputHi, outputAbove200k: outputHi,
            cacheCreateAbove200k: cwHi, cacheReadAbove200k: crHi,
            fastMultiplier: fast
        )
    }
    return out
}

// MARK: - Model name resolution (mirror ccusage)

// ccusage uses the model name as-is (with "-fast" suffix if speed=fast).
// LiteLLM keys can be: "claude-sonnet-4-5", "claude-sonnet-4-5-20250929",
// "anthropic/claude-sonnet-4-5", "anthropic.claude-sonnet-4-5-v1:0", etc.
// JSONL writes the same forms. Match by exact key first, then by prefix.

func resolvePricing(model: String, pricing: [String: ModelPricing]) -> ModelPricing? {
    if let exact = pricing[model] { return exact }
    // Try common provider prefixes the JSONL never uses but LiteLLM might
    let candidates = ["anthropic/\(model)", "anthropic.\(model)"]
    for c in candidates {
        if let v = pricing[c] { return v }
    }
    // Fallback: longest-suffix match (claude-sonnet-4-5-20250929 → claude-sonnet-4-5 if present)
    var bestKey: String?
    for key in pricing.keys {
        if model.hasPrefix(key) || key.hasPrefix(model) {
            if bestKey == nil || key.count > bestKey!.count {
                bestKey = key
            }
        }
    }
    if let k = bestKey { return pricing[k] }
    return nil
}

// MARK: - Tiered cost (200k threshold)

func tieredCost(tokens: Int, baseRate: Double, hiRate: Double?) -> Double {
    let n = Double(tokens)
    guard let hi = hiRate, hi > 0, tokens > 200_000 else {
        return n * baseRate
    }
    return 200_000 * baseRate + (n - 200_000) * hi
}

// MARK: - Data structures

struct Bucket {
    var input: Int = 0
    var output: Int = 0
    var cacheCreate: Int = 0
    var cacheRead: Int = 0
    var cost: Double = 0
    var requestCount: Int = 0
}

// Key: (date, model)
struct AggKey: Hashable {
    let date: String
    let model: String
}

// Global dedup entry — keeps the winning row for each uniqueHash.
struct DedupEntry {
    let key: AggKey
    let bucket: Bucket
    let tokenTotal: Int
    let hasSpeed: Bool
}

// MARK: - JSONL walker

func walkJSONL(root: String) -> [String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: root) else { return [] }
    var files: [String] = []
    while let rel = enumerator.nextObject() as? String {
        if rel.hasSuffix(".jsonl") {
            files.append(root + "/" + rel)
        }
    }
    return files
}

/// Earliest ISO timestamp in a JSONL file, used to match ccusage's
/// `sortFilesByTimestamp` ordering. Files without any parseable timestamp
/// sort to the end.
func earliestTimestamp(in path: String) -> Date? {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    var earliest: Date?
    content.enumerateLines { line, _ in
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let d = f1.date(from: ts) ?? f2.date(from: ts) else { return }
        if earliest == nil || d < earliest! { earliest = d }
    }
    return earliest
}

func sortFilesByTimestamp(_ files: [String]) -> [String] {
    struct E { let file: String; let ts: Date? }
    let entries = files.map { E(file: $0, ts: earliestTimestamp(in: $0)) }
    return entries.sorted { a, b in
        switch (a.ts, b.ts) {
        case let (.some(x), .some(y)): return x < y
        case (.none, .some): return false  // null goes last
        case (.some, .none): return true
        case (.none, .none): return false
        }
    }.map { $0.file }
}

// MARK: - Line parsing

func extractDate(from timestamp: String) -> String? {
    // Parse ISO8601 (with or without fractional seconds), bucket to local yyyy-MM-dd
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    guard let date = f1.date(from: timestamp) ?? f2.date(from: timestamp) else { return nil }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")
    return df.string(from: date)
}

// MARK: - Main

let homeDir = NSHomeDirectory()
let projectsRoot = "\(homeDir)/.claude/projects"

FileHandle.standardError.write("[scan] root=\(projectsRoot)\n".data(using: .utf8)!)
let pricing = fetchPricing()
FileHandle.standardError.write("[pricing] \(pricing.count) models loaded\n".data(using: .utf8)!)

let rawFiles = walkJSONL(root: projectsRoot)
FileHandle.standardError.write("[scan] found \(rawFiles.count) .jsonl files, sorting by earliest timestamp...\n".data(using: .utf8)!)
let allFiles = sortFilesByTimestamp(rawFiles)
FileHandle.standardError.write("[scan] sorted.\n".data(using: .utf8)!)

// Cutoff: keep entries whose date is within last N days (local)
let cutoffDate: String = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")
    let cal = Calendar.current
    let cutoff = cal.date(byAdding: .day, value: -(args.days - 1), to: Date())!
    return df.string(from: cal.startOfDay(for: cutoff))
}()
FileHandle.standardError.write("[scan] keeping dates >= \(cutoffDate)\n".data(using: .utf8)!)

// ccusage 20.x dedup: GLOBAL on uniqueHash, keeping the copy with the LARGEST
// output_tokens. A single assistant message is written more than once (a partial
// streaming snapshot plus the final copy) sharing one msgid:requestId; input and
// cache tokens are identical across copies, only output_tokens grows. ccusage
// 18.0.11 kept the FIRST copy (often the partial, undercounting output); 20.x
// keeps the final/complete one. We track the winning row per hash and replace it
// when a larger-output copy arrives — order-independent, so it doesn't depend on
// matching the binary's exact file-traversal order.
var hashToIndex: [String: Int] = [:]
// Final aggregated output. Built by appending each kept row to its (date, model) bucket.
var keptRows: [(key: AggKey, bucket: Bucket)] = []

var rowsParsed = 0
var rowsKept = 0
var rowsSkippedDate = 0
var rowsMissingPricing = 0
var unknownModels: [String: Int] = [:]

for path in allFiles {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else { continue }
    content.enumerateLines { line, _ in
        guard !line.isEmpty,
              let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        // === ccusage strict schema mirror ===
        // Reject rows with malformed timestamp.
        guard let timestamp = obj["timestamp"] as? String else { return }
        // ISO_TIMESTAMP_PATTERN: /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/
        let tsValid = (timestamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$"#, options: .regularExpression) != nil)
        if !tsValid { return }

        // version: if present, must be string matching VERSION_PATTERN (^\d+\.\d+\.\d+).
        if let v = obj["version"] {
            guard let vs = v as? String,
                  vs.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil else { return }
        }

        // Optional non-empty strings: if present and a string, must be non-empty.
        for k in ["sessionId", "requestId"] {
            if let any = obj[k] {
                if let s = any as? String { if s.isEmpty { return } } else if !(any is NSNull) { return }
            }
        }

        // costUSD: if present and a number, OK; if null we let it pass (we don't use it).
        // ccusage rejects rows where typeof costUSD !== 'number' and !== undefined. We diverge here
        // intentionally because JSON null reading in Swift is awkward; we don't depend on costUSD.

        // isApiErrorMessage: tolerate.

        guard let date = extractDate(from: timestamp) else { return }
        if date < cutoffDate { rowsSkippedDate += 1; return }

        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int
        else { return }
        let cw = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
        // Cache writes split by TTL: 1-hour writes bill higher than the 5-minute
        // default. Claude Code uses 1h caching for ~90%+ of writes, so this split
        // dominates cost. ccusage <19 ignored it (flat 5m rate); 20.x prices it.
        let cw1h = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int) ?? 0

        // message.model / message.id: if present, must be non-empty string.
        if let m = message["model"], !(m is NSNull) {
            guard let s = m as? String, !s.isEmpty else { return }
        }
        if let m = message["id"], !(m is NSNull) {
            guard let s = m as? String, !s.isEmpty else { return }
        }

        // usage.speed: must be undefined / 'standard' / 'fast'.
        let speed = usage["speed"] as? String
        if let any = usage["speed"], !(any is NSNull) {
            guard let s = any as? String, s == "standard" || s == "fast" else { return }
            _ = s
        }
        let hasSpeed = (speed != nil)

        var model = (message["model"] as? String) ?? "unknown"
        // ccusage: formatUsageModelName appends "-fast" if speed=fast (for display only;
        // pricing still resolves to the base model with a fast multiplier).
        let isFast = (speed == "fast")
        let modelKey: String = isFast ? "\(model)-fast" : model

        rowsParsed += 1

        // Cost calc with 200k tier + fast multiplier
        var cost: Double = 0
        if let p = resolvePricing(model: model, pricing: pricing) {
            // Cache-creation cost: bill the 1-hour-TTL tokens at the higher 1h
            // rate; the rest stay at the 5-minute rate, which carries the 200k
            // tier when the model defines one. No first-party Claude Code model
            // defines BOTH a 1h rate and a 200k tier, so this is exact for every
            // model seen here; the combined 1h+200k rate a few Bedrock/legacy ids
            // publish is not modeled (those never appear in ~/.claude/projects).
            // `min` guards a malformed cw1h > cw.
            let cacheCreateCost: Double
            if let r1h = p.cacheCreate1hPerToken, cw1h > 0 {
                let oneHour = min(cw1h, cw)
                cacheCreateCost = tieredCost(tokens: cw - oneHour, baseRate: p.cacheCreatePerToken, hiRate: p.cacheCreateAbove200k)
                                + tieredCost(tokens: oneHour, baseRate: r1h, hiRate: p.cacheCreateAbove200k)
            } else {
                cacheCreateCost = tieredCost(tokens: cw, baseRate: p.cacheCreatePerToken, hiRate: p.cacheCreateAbove200k)
            }
            let base = tieredCost(tokens: input, baseRate: p.inputPerToken, hiRate: p.inputAbove200k)
                     + tieredCost(tokens: output, baseRate: p.outputPerToken, hiRate: p.outputAbove200k)
                     + cacheCreateCost
                     + tieredCost(tokens: cr, baseRate: p.cacheReadPerToken, hiRate: p.cacheReadAbove200k)
            let mult = isFast ? (p.fastMultiplier ?? 1.0) : 1.0
            cost = base * mult
        } else {
            rowsMissingPricing += 1
            unknownModels[model, default: 0] += 1
        }

        let messageId = message["id"] as? String
        let requestId = obj["requestId"] as? String

        let key = AggKey(date: date, model: modelKey)
        let bucket = Bucket(input: input, output: output, cacheCreate: cw, cacheRead: cr, cost: cost, requestCount: 1)

        // Global max-output-wins dedup, matching ccusage 20.x. Duplicate copies of
        // one message (same msgid:requestId) differ only in output_tokens (partial
        // vs final write); keep the largest-output copy. Rows with missing
        // messageId or requestId have uniqueHash=null and are never deduped; every
        // occurrence is kept (matches ccusage).
        if let m = messageId, let r = requestId {
            let hash = "\(m):\(r)"
            if let idx = hashToIndex[hash] {
                if output > keptRows[idx].bucket.output {
                    keptRows[idx] = (key, bucket)
                }
                return
            }
            hashToIndex[hash] = keptRows.count
        }

        keptRows.append((key, bucket))
        rowsKept += 1
        _ = hasSpeed
        _ = model
    }
}

FileHandle.standardError.write(
    "[parse] parsed=\(rowsParsed) kept=\(rowsKept) skipped_date=\(rowsSkippedDate) missing_pricing=\(rowsMissingPricing)\n"
        .data(using: .utf8)!)
if !unknownModels.isEmpty {
    let top = unknownModels.sorted { $0.value > $1.value }.prefix(10)
    FileHandle.standardError.write("[parse] unknown models (top 10):\n".data(using: .utf8)!)
    for (m, c) in top {
        FileHandle.standardError.write("  \(m) × \(c)\n".data(using: .utf8)!)
    }
}

// Aggregate kept rows into the final (date, model) buckets
var agg: [AggKey: Bucket] = [:]
for (key, b) in keptRows {
    var cur = agg[key] ?? Bucket()
    cur.input += b.input
    cur.output += b.output
    cur.cacheCreate += b.cacheCreate
    cur.cacheRead += b.cacheRead
    cur.cost += b.cost
    cur.requestCount += b.requestCount
    agg[key] = cur
}

// MARK: - Output

let sortedKeys = agg.keys.sorted { a, b in
    if a.date != b.date { return a.date > b.date }
    return a.model < b.model
}

if args.jsonOutput {
    var rows: [[String: Any]] = []
    for k in sortedKeys {
        let b = agg[k]!
        rows.append([
            "date": k.date,
            "model": k.model,
            "input_tokens": b.input,
            "output_tokens": b.output,
            "cache_creation_tokens": b.cacheCreate,
            "cache_read_tokens": b.cacheRead,
            "cost_usd": b.cost,
            "request_count": b.requestCount,
        ])
    }
    let out: [String: Any] = [
        "days": args.days,
        "cutoff_date": cutoffDate,
        "rows": rows,
    ]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    func padR(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    func padL(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
    }
    func fmtInt(_ n: Int, _ w: Int) -> String { padL(String(n), w) }
    func fmtDollars(_ d: Double) -> String { String(format: "%.4f", d) }

    let header = "\(padR("date", 12))  \(padR("model", 42))  \(padL("input", 12))  \(padL("output", 12))  \(padL("cache_create", 14))  \(padL("cache_read", 14))  \(padL("cost_usd", 10))"
    print(header)
    print(String(repeating: "-", count: header.count))

    var totalsByDate: [String: Bucket] = [:]
    for k in sortedKeys {
        let b = agg[k]!
        print("\(padR(k.date, 12))  \(padR(k.model, 42))  \(fmtInt(b.input, 12))  \(fmtInt(b.output, 12))  \(fmtInt(b.cacheCreate, 14))  \(fmtInt(b.cacheRead, 14))  \(padL(fmtDollars(b.cost), 10))")
        var d = totalsByDate[k.date] ?? Bucket()
        d.input += b.input; d.output += b.output; d.cacheCreate += b.cacheCreate
        d.cacheRead += b.cacheRead; d.cost += b.cost
        totalsByDate[k.date] = d
    }
    print(String(repeating: "-", count: header.count))
    print("Daily totals:")
    for date in totalsByDate.keys.sorted(by: >) {
        let b = totalsByDate[date]!
        print("  \(padR(date, 10))  in=\(fmtInt(b.input, 10))  out=\(fmtInt(b.output, 10))  cw=\(fmtInt(b.cacheCreate, 10))  cr=\(fmtInt(b.cacheRead, 10))  $\(fmtDollars(b.cost))")
    }
}
