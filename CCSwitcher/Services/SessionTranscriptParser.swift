import Foundation
import CryptoKit

// Typed transcript parse results. The legacy import decoder lives separately in UsageDatabase.
struct CachedEntryV2: Codable, Sendable {
    /// "messageId:requestId", or nil if either id was missing.
    /// nil-hash entries are NEVER deduped — every occurrence is kept.
    var timestampUnix: Double? = nil
    let hash: String?
    let date: String        // local "yyyy-MM-dd"
    let hour: Int           // local 0–23
    let model: String       // raw model id from JSONL, including dated suffixes
    let speed: String?      // nil / "standard" / "fast"
    let input: Int
    let output: Int
    let cw: Int             // cache_creation_input_tokens (total)
    let cw1h: Int           // cache_creation.ephemeral_1h_input_tokens (1-hour TTL portion)
    let cr: Int             // cache_read_input_tokens
    let costUSDRow: Double? // value of `costUSD` if present in the JSONL row
    let tools: [String: Int]
    let linesWritten: Int
}

/// One JSONL file's parse result.
///
/// Cost data lives in `entries` (subject to global dedup).
/// Activity data lives in `activityByDate` as already-summed per-day
/// totals — activity counts (turns, active-minutes, tool counts, lines)
/// don't have the cross-file resume-duplicate problem cost has, so
/// per-file aggregation is correct and cheap.
struct CachedFileV2: Codable, Sendable {
    var contentHash: String? = nil
    var prefixHash: String? = nil
    let mtimeUnix: Double               // bit-equal-comparable with FS mtime
    let earliestTimestampUnix: Double   // for cross-file sort order; .greatestFiniteMagnitude = "no timestamp, sorts last" (must stay finite — see save())
    let project: String                 // dir name under ~/.claude/projects/
    let sessionId: String?              // from the file's first row, if present
    let isSidechain: Bool               // true if path contains /subagents/
    let entries: [CachedEntryV2]
    let activityByDate: [String: ActivityDayContributionV2]
}

struct ActivityDayContributionV2: Codable, Sendable {
    let turns: Int
    let activeMinutes: Int
    let toolCounts: [String: Int]
    let linesWritten: Int
    let modelCounts: [String: Int]  // short name (Opus/Sonnet/Haiku)
}


func parseSessionFile(at path: String, relativePath: String, mtime: Double, timezone: TimeZone, previousSize: Int64? = nil) -> CachedFileV2? {
    autoreleasepool {
        parseTranscript(at: path, relativePath: relativePath, mtime: mtime, timezone: timezone, previousSize: previousSize)
    }
}

private func parseTranscript(at path: String, relativePath: String, mtime: Double, timezone: TimeZone, previousSize: Int64?) -> CachedFileV2? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }

    let isoMain = ISO8601DateFormatter()
    isoMain.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoAlt = ISO8601DateFormatter()
    isoAlt.formatOptions = [.withInternetDateTime]

    let dateFmt = DateFormatter()
    dateFmt.timeZone = timezone
    dateFmt.dateFormat = "yyyy-MM-dd"
    dateFmt.locale = Locale(identifier: "en_US_POSIX")
    let hourFmt = DateFormatter()
    hourFmt.timeZone = timezone
    hourFmt.dateFormat = "H"
    hourFmt.locale = Locale(identifier: "en_US_POSIX")

    // File-level metadata (project, sessionId, isSidechain) is determined
    // by path shape; we infer it without scanning the JSON.
    let project: String = {
        let parts = relativePath.split(separator: "/")
        return parts.first.map(String.init) ?? "unknown"
    }()
    let isSidechain = relativePath.contains("/subagents/")
    var sessionId: String?
    var earliest: Date?

    // Per-file cost dedup state.
    var perFileBest: [String: Int] = [:]   // hash -> index of current max-output winner in costEntries
    var costEntries: [CachedEntryV2] = []

    // Per-date activity bookkeeping.
    var perDayTurns: [String: Int] = [:]
    var perDayTools: [String: [String: Int]] = [:]
    var perDayModels: [String: [String: Int]] = [:]
    var perDayLines: [String: Int] = [:]
    var perDayTimestamps: [String: [Date]] = [:]
    var perDayActivityRequestSeen: Set<String> = []

    // Strict schema regexes — originally lifted from ccusage 18.0.11's JS parser;
    // the row-acceptance schema is unchanged in 20.x (token columns still reconcile).
    // Bare patterns; ranges checked with `.regularExpression`.
    let timestampPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$"#
    let versionPattern   = #"^\d+\.\d+\.\d+"#

    // JSONL records end at LF bytes; Unicode separators inside strings are content.
    data.split(separator: 0x0A).forEach { line in autoreleasepool {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        else { return }

        guard let timestampStr = obj["timestamp"] as? String,
              timestampStr.range(of: timestampPattern, options: .regularExpression) != nil,
              let timestamp = isoMain.date(from: timestampStr) ?? isoAlt.date(from: timestampStr)
        else { return }

        // `version`: if present, must match `^\d+\.\d+\.\d+`. Stale Claude
        // Code writes occasionally produce non-version strings here.
        if let v = obj["version"] {
            guard let vs = v as? String,
                  vs.range(of: versionPattern, options: .regularExpression) != nil else { return }
        }

        if earliest == nil || timestamp < earliest! { earliest = timestamp }
        if sessionId == nil, let s = obj["sessionId"] as? String, !s.isEmpty { sessionId = s }

        let dateStr = dateFmt.string(from: timestamp)
        let hour = Int(hourFmt.string(from: timestamp)) ?? 0
        let type = obj["type"] as? String ?? ""

        perDayTimestamps[dateStr, default: []].append(timestamp)

        switch type {
        case "user":
            let message = obj["message"] as? [String: Any]
            let rawContent = message?["content"]
            if let s = rawContent as? String, !s.isEmpty {
                perDayTurns[dateStr, default: 0] += 1
            } else if let arr = rawContent as? [[String: Any]] {
                let hasToolResult = arr.contains { $0["type"] as? String == "tool_result" }
                if !hasToolResult { perDayTurns[dateStr, default: 0] += 1 }
            }

        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return }

            // === Cost entry path (ccusage parity) ===
            // Match ccusage: any row with numeric input/output_tokens
            // gets its own entry. Schema is loose; rows with `<synthetic>` model
            // contribute zero-token entries, which is intentional — they're filtered
            // out from cost breakdowns at presentation time.
            if let usage = message["usage"] as? [String: Any],
               let input = usage["input_tokens"] as? Int,
               let output = usage["output_tokens"] as? Int {
                let cw = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                // 1-hour-TTL portion of the cache write (billed higher than 5m).
                let cw1h = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int) ?? 0
                let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
                // `speed`: ccusage rejects values other than nil/"standard"/"fast".
                let rawSpeed = usage["speed"]
                let speed: String?
                if rawSpeed is NSNull || rawSpeed == nil {
                    speed = nil
                } else if let s = rawSpeed as? String, s == "standard" || s == "fast" {
                    speed = s
                } else {
                    return  // unsupported value -> reject row (matches reference)
                }
                // Non-empty-string requirements for id-like fields. An empty
                // string would collapse hash buckets like `":req_xxx"` → false dedup.
                let modelRaw = (message["model"] as? String) ?? ""
                guard !modelRaw.isEmpty else { return }
                let model = modelRaw

                let messageId: String? = {
                    guard let s = message["id"] as? String, !s.isEmpty else { return nil }
                    return s
                }()
                let requestId: String? = {
                    guard let s = obj["requestId"] as? String, !s.isEmpty else { return nil }
                    return s
                }()
                let costUSD = obj["costUSD"] as? Double
                let hash: String? = {
                    if let m = messageId, let r = requestId { return "\(m):\(r)" }
                    return nil
                }()

                // Tool counts + linesWritten for THIS row, attached at entry
                // level so we can slice cost-by-tool later if needed.
                var rowTools: [String: Int] = [:]
                var rowLines = 0
                if let arr = message["content"] as? [[String: Any]] {
                    for block in arr where (block["type"] as? String) == "tool_use" {
                        guard let toolName = block["name"] as? String else { continue }
                        rowTools[toolName, default: 0] += 1
                        if let input = block["input"] as? [String: Any] {
                            rowLines += estimateLines(tool: toolName, input: input)
                        }
                    }
                }
                let entry = CachedEntryV2(
                    timestampUnix: timestamp.timeIntervalSince1970,
                    hash: hash,
                    date: dateStr,
                    hour: hour,
                    model: model,
                    speed: speed,
                    input: input, output: output, cw: cw, cw1h: cw1h, cr: cr,
                    costUSDRow: costUSD,
                    tools: rowTools,
                    linesWritten: rowLines
                )
                // Per-file max-output-wins dedup. A message written more than once
                // (partial stream snapshot + final copy) shares a hash; input/cache
                // are identical across copies, only output_tokens grows, so keep the
                // largest-output copy. Global dedup happens later in costSummary.
                // nil-hash rows are never deduped — every occurrence is kept.
                if let h = hash {
                    if let idx = perFileBest[h] {
                        if output > costEntries[idx].output { costEntries[idx] = entry }
                    } else {
                        perFileBest[h] = costEntries.count
                        costEntries.append(entry)
                    }
                } else {
                    costEntries.append(entry)
                }
            }

            // === Activity-data path (file-level aggregation) ===
            // Matches v1 semantics: model usage deduped by requestId within file,
            // tool counts and linesWritten summed across all assistant rows
            // (not just deduped winners).
            if let model = message["model"] as? String,
               let requestId = obj["requestId"] as? String,
               !perDayActivityRequestSeen.contains(requestId) {
                perDayActivityRequestSeen.insert(requestId)
                let short = CostParser.shortModelName(model)
                perDayModels[dateStr, default: [:]][short, default: 0] += 1
            }
            if let arr = message["content"] as? [[String: Any]] {
                for block in arr where (block["type"] as? String) == "tool_use" {
                    guard let toolName = block["name"] as? String else { continue }
                    perDayTools[dateStr, default: [:]][toolName, default: 0] += 1
                    if let input = block["input"] as? [String: Any] {
                        perDayLines[dateStr, default: 0] += estimateLines(tool: toolName, input: input)
                    }
                }
            }

        default: break
        }
    } }

    // Reduce activity per-day.
    var activityOut: [String: ActivityDayContributionV2] = [:]
    let allDates = Set(perDayTurns.keys)
        .union(perDayTools.keys)
        .union(perDayModels.keys)
        .union(perDayLines.keys)
        .union(perDayTimestamps.keys)
    for date in allDates {
        let active = calculateActiveMinutes(perDayTimestamps[date] ?? [])
        let c = ActivityDayContributionV2(
            turns: perDayTurns[date] ?? 0,
            activeMinutes: active,
            toolCounts: perDayTools[date] ?? [:],
            linesWritten: perDayLines[date] ?? 0,
            modelCounts: perDayModels[date] ?? [:]
        )
        if c.turns > 0 || c.activeMinutes > 0 || !c.toolCounts.isEmpty
            || c.linesWritten > 0 || !c.modelCounts.isEmpty {
            activityOut[date] = c
        }
    }

    return CachedFileV2(
        contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        prefixHash: previousSize.flatMap { size in
            guard size >= 0, size <= data.count else { return nil }
            return SHA256.hash(data: data.prefix(Int(size))).map { String(format: "%02x", $0) }.joined()
        },
        mtimeUnix: mtime,
        // Must stay FINITE: JSONEncoder rejects non-finite floats by default, so a
        // single timestamp-less file with .infinity here made save() throw and the
        // whole cache silently never persisted (forcing a full re-parse every
        // cycle). .greatestFiniteMagnitude still sorts after every real timestamp.
        earliestTimestampUnix: earliest?.timeIntervalSince1970 ?? .greatestFiniteMagnitude,
        project: project,
        sessionId: sessionId,
        isSidechain: isSidechain,
        entries: costEntries,
        activityByDate: activityOut
    )
}

/// Active coding minutes from a single date's timestamp set. Mirrors v1's
/// algorithm (10-min idle gap splits sessions, 2-min tail padding).
private func calculateActiveMinutes(_ timestamps: [Date]) -> Int {
    let maxGap: TimeInterval = 10 * 60
    let tailPadding: TimeInterval = 2 * 60
    guard timestamps.count >= 2 else {
        return timestamps.isEmpty ? 0 : max(1, Int(tailPadding / 60))
    }
    let sorted = timestamps.sorted()
    var total: TimeInterval = 0
    var periodStart = sorted[0]
    var periodEnd = sorted[0]
    for i in 1..<sorted.count {
        let gap = sorted[i].timeIntervalSince(periodEnd)
        if gap <= maxGap {
            periodEnd = sorted[i]
        } else {
            total += periodEnd.timeIntervalSince(periodStart) + tailPadding
            periodStart = sorted[i]
            periodEnd = sorted[i]
        }
    }
    total += periodEnd.timeIntervalSince(periodStart) + tailPadding
    return total > 0 ? max(1, Int(total / 60)) : 0
}

private func estimateLines(tool: String, input: [String: Any]) -> Int {
    switch tool {
    case "Write":
        let content = input["content"] as? String ?? ""
        return content.components(separatedBy: "\n").count
    case "Edit":
        let newStr = input["new_string"] as? String ?? ""
        let oldStr = input["old_string"] as? String ?? ""
        return max(0, newStr.components(separatedBy: "\n").count - oldStr.components(separatedBy: "\n").count)
    default:
        return 0
    }
}
