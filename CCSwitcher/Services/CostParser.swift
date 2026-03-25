import Foundation

private let log = FileLog("CostParser")

/// Parses Claude Code session JSONL files to calculate token costs.
final class CostParser: Sendable {
    static let shared = CostParser()

    private let claudeDir: String

    private init() {
        self.claudeDir = NSHomeDirectory() + "/.claude"
    }

    // MARK: - Public

    /// Compute cost summary from all session JSONL files.
    func getCostSummary() -> CostSummary {
        let usages = parseAllSessions()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())

        // Group by date
        var dateGroups: [String: [TokenUsage]] = [:]
        var dateSessionFiles: [String: Set<String>] = [:]
        for usage in usages {
            let dateStr = formatter.string(from: usage.timestamp)
            dateGroups[dateStr, default: []].append(usage)
            dateSessionFiles[dateStr, default: []].insert(usage.sessionFile)
        }

        // Build daily costs
        var dailyCosts: [DailyCost] = []
        for (date, usages) in dateGroups {
            var modelCosts: [String: Double] = [:]
            var totalInput = 0, totalOutput = 0, totalCacheWrite = 0, totalCacheRead = 0

            for u in usages {
                let cost = u.cost
                let shortModel = Self.shortModelName(u.model)
                modelCosts[shortModel, default: 0] += cost
                totalInput += u.inputTokens
                totalOutput += u.outputTokens
                totalCacheWrite += u.cacheWriteTokens
                totalCacheRead += u.cacheReadTokens
            }

            dailyCosts.append(DailyCost(
                date: date,
                totalCost: modelCosts.values.reduce(0, +),
                modelBreakdown: modelCosts,
                sessionCount: dateSessionFiles[date]?.count ?? 0,
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheWriteTokens: totalCacheWrite,
                cacheReadTokens: totalCacheRead
            ))
        }

        dailyCosts.sort { $0.date > $1.date } // newest first

        let todayCost = dailyCosts.first(where: { $0.date == todayStr })?.totalCost ?? 0

        log.info("[getCostSummary] Parsed \(usages.count) usage entries, \(dailyCosts.count) days, today=$\(String(format: "%.2f", todayCost))")
        return CostSummary(todayCost: todayCost, dailyCosts: dailyCosts)
    }

    // MARK: - Parsing

    /// Parse all session JSONL files, deduplicating by requestId to avoid
    /// counting streaming updates multiple times for the same API call.
    private func parseAllSessions() -> [TokenUsage] {
        let projectsDir = claudeDir + "/projects"
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            log.warning("[parseAllSessions] Cannot read projects directory")
            return []
        }

        var allUsages: [TokenUsage] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        for projectDir in projectDirs {
            let projectPath = projectsDir + "/" + projectDir
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + file
                let sessionFile = file.replacingOccurrences(of: ".jsonl", with: "")
                guard let data = fm.contents(atPath: filePath),
                      let content = String(data: data, encoding: .utf8) else { continue }

                // Deduplicate: keep only the last entry per requestId.
                // Streaming creates multiple assistant entries with the same requestId;
                // the last one has the final (correct) token counts.
                var requestEntries: [String: TokenUsage] = [:]

                for line in content.components(separatedBy: .newlines) {
                    guard !line.isEmpty else { continue }
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                    guard let type = obj["type"] as? String, type == "assistant",
                          let message = obj["message"] as? [String: Any],
                          let model = message["model"] as? String,
                          let usage = message["usage"] as? [String: Any],
                          let timestampStr = obj["timestamp"] as? String,
                          let requestId = obj["requestId"] as? String else { continue }

                    // Skip synthetic/unknown models
                    guard ModelPricing.forModel(model) != nil else { continue }

                    let timestamp = isoFormatter.date(from: timestampStr)
                        ?? isoFallback.date(from: timestampStr)
                        ?? Date()

                    let tokenUsage = TokenUsage(
                        inputTokens: usage["input_tokens"] as? Int ?? 0,
                        outputTokens: usage["output_tokens"] as? Int ?? 0,
                        cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                        cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                        model: model,
                        timestamp: timestamp,
                        sessionFile: sessionFile
                    )

                    // Always overwrite — last entry for this requestId wins
                    requestEntries[requestId] = tokenUsage
                }

                allUsages.append(contentsOf: requestEntries.values)
            }
        }

        return allUsages
    }

    // MARK: - Helpers

    /// "claude-opus-4-6" → "Opus"
    static func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}
