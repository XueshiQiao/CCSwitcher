import Foundation

// MARK: - DEPRECATED — superseded by SessionParseCacheV2
//
// Kept compiled (no live callers) for one release cycle in case a fast
// rollback is needed. Remove the whole file after 1.6.x ships and we're
// confident in v2. The old on-disk cache file `session-parse-cache.json`
// is harmlessly ignored once v2 takes over.

private let log = FileLog("Cache")

// MARK: - Cache Models

/// Per-file aggregated parse output, keyed by date string ("yyyy-MM-dd").
/// Stored on disk so successive refreshes can skip re-parsing unchanged files.
struct CachedFile: Codable, Sendable {
    /// Modification time at the moment this entry was produced.
    /// Stored as Unix seconds (Double) to avoid ISO8601 fractional-second
    /// round-trip drift, so equality with FS mtime is bit-precise.
    let mtimeUnix: Double
    let costByDate: [String: CostDayContribution]
    let activityByDate: [String: ActivityDayContribution]
}

/// Per-day, per-model token totals contributed by a single JSONL file.
/// Already deduplicated by requestId at parse time.
struct CostDayContribution: Codable, Sendable {
    let modelTokens: [String: ModelTokens]
}

struct ModelTokens: Codable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let requestCount: Int
}

/// Per-day activity contribution by a single JSONL file (one session = one file).
struct ActivityDayContribution: Codable, Sendable {
    let turns: Int
    let activeMinutes: Int
    let toolCounts: [String: Int]
    let linesWritten: Int
    let modelCounts: [String: Int]  // short name (Opus/Sonnet/Haiku)
}

private struct CacheEnvelope: Codable {
    let version: Int
    let lastUpdated: Date
    var files: [String: CachedFile]
}

// MARK: - Aggregation Outputs (per-file parse result)

private struct ParsedFile {
    let costByDate: [String: CostDayContribution]
    let activityByDate: [String: ActivityDayContribution]
}

// MARK: - SessionParseCache (actor)

/// Owns the disk cache of parsed Claude Code session JSONL files.
/// All access is serialized through the actor; the cache file is written
/// atomically (temp + rename) so a crash mid-save cannot corrupt it.
actor SessionParseCache {
    static let shared = SessionParseCache()

    private static let currentVersion = 1
    private let claudeProjectsDir: String
    private let cacheURL: URL
    private var files: [String: CachedFile] = [:]
    private var loaded = false

    private init() {
        self.claudeProjectsDir = NSHomeDirectory() + "/.claude/projects"

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("session-parse-cache.json")
    }

    // MARK: Public API

    /// Walks `~/.claude/projects/<project>/*.jsonl`, reusing cached parse
    /// output for files whose mtime is unchanged and re-parsing the rest.
    ///
    /// The body has NO internal `await` — the actor's executor is held
    /// end-to-end, so concurrent callers see strictly serial execution
    /// (the second caller waits for the first to fully finish, then sees
    /// the populated cache). The actor runs on the cooperative pool, not
    /// the main thread, so the UI is never blocked.
    func refreshFromFilesystem() {
        ensureLoaded()
        let start = Date()

        // Snapshot mtimes of currently-cached files; passed to the static
        // scanner so it has no need to touch actor state mid-parse.
        let cachedMtimes: [String: Double] = files.mapValues { $0.mtimeUnix }

        let result = Self.scanAndParse(projectsDir: claudeProjectsDir, cachedMtimes: cachedMtimes)

        // Apply updates and evictions on the actor.
        for (path, entry) in result.updates {
            files[path] = entry
        }
        var evicted = 0
        for path in files.keys where !result.livePaths.contains(path) {
            files.removeValue(forKey: path)
            evicted += 1
            log.debug("EVICT \(path) reason=file-deleted")
        }

        let totalMs = Int(Date().timeIntervalSince(start) * 1000)
        log.info(
            "refresh: scanned=\(result.livePaths.count) " +
            "hit=\(result.hits) miss=\(result.missesNew + result.missesMtime) " +
            "(new=\(result.missesNew), mtime=\(result.missesMtime)) " +
            "evicted=\(evicted) parse_total=\(result.parseElapsedMs)ms total=\(totalMs)ms"
        )

        save()
    }

    // Result of a one-shot scan + parse pass.
    private struct ScanResult {
        let livePaths: Set<String>
        let updates: [String: CachedFile]
        let hits: Int
        let missesNew: Int
        let missesMtime: Int
        let parseElapsedMs: Int
    }

    private static func scanAndParse(
        projectsDir: String,
        cachedMtimes: [String: Double]
    ) -> ScanResult {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            log.warning("refresh: cannot read projects dir \(projectsDir)")
            return ScanResult(livePaths: [], updates: [:], hits: 0, missesNew: 0, missesMtime: 0, parseElapsedMs: 0)
        }

        var livePaths: Set<String> = []
        var updates: [String: CachedFile] = [:]
        var hits = 0
        var missesNew = 0
        var missesMtime = 0
        var parseElapsedMs = 0

        for projectDir in projectDirs {
            let projectPath = projectsDir + "/" + projectDir
            // Direct children only — matches pre-cache parser semantics
            // (subagent JSONL files live in nested dirs and were never parsed).
            guard let entries = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            for entry in entries where entry.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + entry
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtimeDate = attrs[.modificationDate] as? Date else { continue }
                let mtime = mtimeDate.timeIntervalSince1970
                livePaths.insert(filePath)

                if let cachedMtime = cachedMtimes[filePath], cachedMtime == mtime {
                    hits += 1
                    continue
                }

                let isNew = cachedMtimes[filePath] == nil
                let reason = isNew ? "new-file" : "mtime-changed"
                if isNew { missesNew += 1 } else { missesMtime += 1 }

                let parseStart = Date()
                let parsed = parseJSONLFile(at: filePath)
                let elapsed = Int(Date().timeIntervalSince(parseStart) * 1000)
                parseElapsedMs += elapsed

                updates[filePath] = CachedFile(
                    mtimeUnix: mtime,
                    costByDate: parsed.costByDate,
                    activityByDate: parsed.activityByDate
                )
                log.debug(
                    "MISS \(filePath) reason=\(reason) " +
                    "cost_dates=\(parsed.costByDate.count) " +
                    "activity_dates=\(parsed.activityByDate.count) " +
                    "elapsed=\(elapsed)ms"
                )
            }
        }

        return ScanResult(
            livePaths: livePaths,
            updates: updates,
            hits: hits,
            missesNew: missesNew,
            missesMtime: missesMtime,
            parseElapsedMs: parseElapsedMs
        )
    }

    /// Aggregate cost summary from the in-memory cache. Cheap.
    func costSummary() -> CostSummary {
        // date → model → ModelTokens (sum across files)
        var byDate: [String: [String: ModelTokens]] = [:]
        var sessionCountByDate: [String: Int] = [:]

        for (_, file) in files {
            for (date, contribution) in file.costByDate {
                sessionCountByDate[date, default: 0] += 1
                for (model, tokens) in contribution.modelTokens {
                    if let existing = byDate[date]?[model] {
                        byDate[date, default: [:]][model] = ModelTokens(
                            inputTokens: existing.inputTokens + tokens.inputTokens,
                            outputTokens: existing.outputTokens + tokens.outputTokens,
                            cacheWriteTokens: existing.cacheWriteTokens + tokens.cacheWriteTokens,
                            cacheReadTokens: existing.cacheReadTokens + tokens.cacheReadTokens,
                            requestCount: existing.requestCount + tokens.requestCount
                        )
                    } else {
                        byDate[date, default: [:]][model] = tokens
                    }
                }
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())

        var dailyCosts: [DailyCost] = []
        for (date, modelMap) in byDate {
            var modelCosts: [String: Double] = [:]
            var input = 0, output = 0, cw = 0, cr = 0
            for (model, tokens) in modelMap {
                let pricing = ModelPricing.forModel(model)
                let cost: Double
                if let p = pricing {
                    cost = Double(tokens.inputTokens) / 1_000_000 * p.input
                        + Double(tokens.outputTokens) / 1_000_000 * p.output
                        + Double(tokens.cacheWriteTokens) / 1_000_000 * p.cacheWrite
                        + Double(tokens.cacheReadTokens) / 1_000_000 * p.cacheRead
                } else {
                    cost = 0
                }
                let short = CostParser.shortModelName(model)
                modelCosts[short, default: 0] += cost
                input += tokens.inputTokens
                output += tokens.outputTokens
                cw += tokens.cacheWriteTokens
                cr += tokens.cacheReadTokens
            }
            dailyCosts.append(DailyCost(
                date: date,
                totalCost: modelCosts.values.reduce(0, +),
                modelBreakdown: modelCosts,
                sessionCount: sessionCountByDate[date] ?? 0,
                inputTokens: input,
                outputTokens: output,
                cacheWriteTokens: cw,
                cacheReadTokens: cr
            ))
        }
        dailyCosts.sort { $0.date > $1.date }
        let todayCost = dailyCosts.first(where: { $0.date == todayStr })?.totalCost ?? 0
        log.info("costSummary: \(dailyCosts.count) days, today=$\(String(format: "%.2f", todayCost))")
        return CostSummary(todayCost: todayCost, dailyCosts: dailyCosts)
    }

    /// Aggregate today's ActivityStats from the in-memory cache.
    /// Subagent files are excluded (matches prior ActivityParser behavior).
    func activityStatsToday() -> ActivityStats {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())

        var turns = 0, activeMinutes = 0, lines = 0
        var tools: [String: Int] = [:]
        var models: [String: Int] = [:]

        for (path, file) in files {
            if path.contains("/subagents/") { continue }
            guard let day = file.activityByDate[today] else { continue }
            turns += day.turns
            activeMinutes += day.activeMinutes
            lines += day.linesWritten
            for (k, v) in day.toolCounts { tools[k, default: 0] += v }
            for (k, v) in day.modelCounts { models[k, default: 0] += v }
        }

        log.info("activityStatsToday: turns=\(turns) active=\(activeMinutes)m lines=\(lines)")
        return ActivityStats(
            conversationTurns: turns,
            activeCodingMinutes: activeMinutes,
            toolUsage: tools,
            linesWritten: lines,
            modelUsage: models
        )
    }

    // MARK: - Disk I/O

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheURL.path) else {
            log.info("LOAD path=\(cacheURL.path) status=missing")
            return
        }
        let start = Date()
        guard let data = try? Data(contentsOf: cacheURL) else {
            log.warning("LOAD path=\(cacheURL.path) status=read-failed")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(CacheEnvelope.self, from: data) else {
            log.warning("LOAD path=\(cacheURL.path) bytes=\(data.count) status=decode-failed, discarding")
            return
        }
        guard envelope.version == Self.currentVersion else {
            log.info("LOAD version=\(envelope.version) != current=\(Self.currentVersion), discarding")
            return
        }
        files = envelope.files
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        log.info("LOAD path=\(cacheURL.path) bytes=\(data.count) entries=\(files.count) elapsed=\(elapsed)ms")
    }

    private func save() {
        let envelope = CacheEnvelope(
            version: Self.currentVersion,
            lastUpdated: Date(),
            files: files
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else {
            log.error("SAVE failed to encode")
            return
        }
        let start = Date()
        do {
            // `Data.write(.atomic)` writes to a temp file in the same directory
            // and renames atomically. Works whether or not cacheURL exists.
            try data.write(to: cacheURL, options: .atomic)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            log.info("SAVE path=\(cacheURL.path) bytes=\(data.count) entries=\(files.count) elapsed=\(elapsed)ms")
        } catch {
            log.error("SAVE failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Pure parser (file-scope; runs on actor's executor when called)

/// Parse a single JSONL file into per-day cost and activity contributions.
/// Pure: no I/O beyond reading the input file, no side effects on the cache.
private func parseJSONLFile(at path: String) -> ParsedFile {
    let fm = FileManager.default
    guard let data = fm.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
        return ParsedFile(costByDate: [:], activityByDate: [:])
    }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoFallback = ISO8601DateFormatter()
    isoFallback.formatOptions = [.withInternetDateTime]

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"

    // === CostParser bookkeeping ===
    // Streaming creates multiple assistant entries per requestId; the LAST
    // entry has the final token counts. Dedup by requestId only — the
    // retained entry's date is what counts (matches pre-cache behavior
    // even when a streamed request straddles midnight).
    var lastTokensByRequest: [String: (date: String, model: String, tokens: ModelTokens)] = [:]

    // === ActivityParser bookkeeping (per-date) ===
    var seenRequests: Set<String> = []  // model-dedup across the file
    var perDayTurns: [String: Int] = [:]
    var perDayTools: [String: [String: Int]] = [:]
    var perDayModels: [String: [String: Int]] = [:]   // short name (Opus/Sonnet/Haiku)
    var perDayLines: [String: Int] = [:]
    var perDayTimestamps: [String: [Date]] = [:]

    // To avoid heavy `String.components` on a 15MB string (extra allocations),
    // iterate using `enumerateLines` which yields substrings without copying.
    content.enumerateLines { line, _ in
        guard !line.isEmpty,
              let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        guard let timestampStr = obj["timestamp"] as? String,
              let timestamp = isoFormatter.date(from: timestampStr) ?? isoFallback.date(from: timestampStr)
        else { return }

        let date = dateFormatter.string(from: timestamp)
        let type = obj["type"] as? String ?? ""

        // Activity: collect timestamps per date for active-minute calc.
        perDayTimestamps[date, default: []].append(timestamp)

        switch type {
        case "user":
            // Real user input only — exclude tool_result feedback messages.
            let message = obj["message"] as? [String: Any]
            let rawContent = message?["content"]
            if let str = rawContent as? String, !str.isEmpty {
                perDayTurns[date, default: 0] += 1
            } else if let arr = rawContent as? [[String: Any]] {
                let hasToolResult = arr.contains { $0["type"] as? String == "tool_result" }
                if !hasToolResult { perDayTurns[date, default: 0] += 1 }
            }

        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return }

            // Cost: dedup by (date, requestId), keep last entry's tokens.
            if let model = message["model"] as? String,
               let usage = message["usage"] as? [String: Any],
               let requestId = obj["requestId"] as? String,
               ModelPricing.forModel(model) != nil {
                let tokens = ModelTokens(
                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0,
                    cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                    requestCount: 1
                )
                lastTokensByRequest[requestId] = (date, model, tokens)
            }

            // Activity: model dedup by requestId (across the file).
            if let model = message["model"] as? String,
               let requestId = obj["requestId"] as? String,
               !seenRequests.contains(requestId) {
                seenRequests.insert(requestId)
                let short = CostParser.shortModelName(model)
                perDayModels[date, default: [:]][short, default: 0] += 1
            }

            // Activity: tool usage + lines written.
            if let arr = message["content"] as? [[String: Any]] {
                for block in arr {
                    guard let blockType = block["type"] as? String,
                          blockType == "tool_use",
                          let toolName = block["name"] as? String else { continue }
                    perDayTools[date, default: [:]][toolName, default: 0] += 1
                    if let input = block["input"] as? [String: Any] {
                        perDayLines[date, default: 0] += estimateLines(tool: toolName, input: input)
                    }
                }
            }

        default:
            break
        }
    }

    // === Reduce cost: per (date, model) sum across deduped requests ===
    var costByDate: [String: [String: ModelTokens]] = [:]
    for (_, value) in lastTokensByRequest {
        let date = value.date
        let model = value.model
        let t = value.tokens
        if let existing = costByDate[date]?[model] {
            costByDate[date, default: [:]][model] = ModelTokens(
                inputTokens: existing.inputTokens + t.inputTokens,
                outputTokens: existing.outputTokens + t.outputTokens,
                cacheWriteTokens: existing.cacheWriteTokens + t.cacheWriteTokens,
                cacheReadTokens: existing.cacheReadTokens + t.cacheReadTokens,
                requestCount: existing.requestCount + 1
            )
        } else {
            costByDate[date, default: [:]][model] = t
        }
    }
    var costOut: [String: CostDayContribution] = [:]
    for (date, modelMap) in costByDate {
        costOut[date] = CostDayContribution(modelTokens: modelMap)
    }

    // === Reduce activity: compute per-date active minutes from timestamps ===
    var activityOut: [String: ActivityDayContribution] = [:]
    let allDates = Set(perDayTurns.keys)
        .union(perDayTools.keys)
        .union(perDayModels.keys)
        .union(perDayLines.keys)
        .union(perDayTimestamps.keys)

    for date in allDates {
        let active = calculateActiveMinutes(perDayTimestamps[date] ?? [])
        let contribution = ActivityDayContribution(
            turns: perDayTurns[date] ?? 0,
            activeMinutes: active,
            toolCounts: perDayTools[date] ?? [:],
            linesWritten: perDayLines[date] ?? 0,
            modelCounts: perDayModels[date] ?? [:]
        )
        // Keep dates that have any signal.
        if contribution.turns > 0 || contribution.activeMinutes > 0
            || !contribution.toolCounts.isEmpty || contribution.linesWritten > 0
            || !contribution.modelCounts.isEmpty {
            activityOut[date] = contribution
        }
    }

    return ParsedFile(costByDate: costOut, activityByDate: activityOut)
}

/// Active coding minutes for a single session-on-date timestamp set.
/// Same algorithm as the pre-cache ActivityParser, scoped to one date's
/// timestamps (so straddling-midnight sessions split naturally by date).
private func calculateActiveMinutes(_ timestamps: [Date]) -> Int {
    let maxGap: TimeInterval = 10 * 60
    let tailPadding: TimeInterval = 2 * 60

    guard timestamps.count >= 2 else {
        return timestamps.isEmpty ? 0 : max(1, Int(tailPadding / 60))
    }

    let sorted = timestamps.sorted()
    var totalSeconds: TimeInterval = 0
    var periodStart = sorted[0]
    var periodEnd = sorted[0]

    for i in 1..<sorted.count {
        let gap = sorted[i].timeIntervalSince(periodEnd)
        if gap <= maxGap {
            periodEnd = sorted[i]
        } else {
            totalSeconds += periodEnd.timeIntervalSince(periodStart) + tailPadding
            periodStart = sorted[i]
            periodEnd = sorted[i]
        }
    }
    totalSeconds += periodEnd.timeIntervalSince(periodStart) + tailPadding

    return totalSeconds > 0 ? max(1, Int(totalSeconds / 60)) : 0
}

private func estimateLines(tool: String, input: [String: Any]) -> Int {
    switch tool {
    case "Write":
        let content = input["content"] as? String ?? ""
        return content.components(separatedBy: "\n").count
    case "Edit":
        let newStr = input["new_string"] as? String ?? ""
        let oldStr = input["old_string"] as? String ?? ""
        let added = newStr.components(separatedBy: "\n").count
        let removed = oldStr.components(separatedBy: "\n").count
        return max(0, added - removed)
    default:
        return 0
    }
}
