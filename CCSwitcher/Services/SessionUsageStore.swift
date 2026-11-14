import Foundation
import GRDB

private let log = FileLog("UsageStore")

/// Owns scanning and statistics; the database retains historical sources even
/// when Claude cleans its JSONL files. No application credentials are stored here.
actor SessionUsageStore {
    static let shared = SessionUsageStore()
    // Version 2 reparses unchanged sources to recover rows containing Unicode separators.
    static let parserVersion = 2
    static let timezonePreference = "usageReportingTimezone"

    private let databaseURL: URL
    private let projectsRoot: URL
    private let legacyURL: URL?
    private let preferredTimezone: TimeZone
    private let persistTimezonePreference: Bool
    private var storage: UsageDatabase?
    // Retry rejected files when their signature changes, once per process otherwise.
    private var rejectedSources: [String: SessionFileSignature] = [:]

    init(databaseURL: URL? = nil, projectsRoot: URL? = nil, legacyURL: URL? = nil, timezone: TimeZone? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CCSwitcher", isDirectory: true)
        self.databaseURL = databaseURL ?? support.appendingPathComponent("usage.sqlite")
        self.projectsRoot = canonicalUsageSourceURL(projectsRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true))
        self.legacyURL = legacyURL ?? (databaseURL == nil ? support.appendingPathComponent("session-parse-cache-v2.json") : nil)
        self.preferredTimezone = timezone ?? UserDefaults.standard.string(forKey: Self.timezonePreference).flatMap(TimeZone.init(identifier:)) ?? .current
        self.persistTimezonePreference = databaseURL == nil
    }

    private func database() throws -> UsageDatabase {
        if let storage { return storage }
        let db = try UsageDatabase(url: databaseURL, root: projectsRoot, legacyURL: legacyURL, timezone: preferredTimezone)
        storage = db
        if persistTimezonePreference { UserDefaults.standard.set(db.reportingTimezone.identifier, forKey: Self.timezonePreference) }
        return db
    }

    func reportingTimezoneIdentifier() throws -> String { try database().reportingTimezone.identifier }

    /// A successful scan may still report rejected per-file changes. Accepted
    /// files remain usable; failures never masquerade as a fresh empty history.
    func refreshFromFilesystem() async throws -> String? {
        let db = try database()
        await PricingService.shared.ensureLoaded()
        await PricingService.shared.reloadIfFreshChanged()
        PricingService.shared.refreshInBackground()
        return synchronizeSources(db)
    }

    // Also used by the isolated file lifecycle tests without touching network pricing.
    func refreshLocalFiles() throws -> String? { synchronizeSources(try database()) }

    private func synchronizeSources(_ db: UsageDatabase) -> String? {
        do { return try scan(db) }
        catch {
            log.warning("Source scan unavailable; retaining stored history: \(error.localizedDescription)")
            return String(format: NSLocalizedString("usage_storage_scan_failed", bundle: L10n.bundle, comment: "Usage scan failure"), error.localizedDescription)
        }
    }

    private func scan(_ db: UsageDatabase) throws -> String? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: projectsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(at: projectsRoot, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            enumerationFailed = true
            return true
        }) else { throw CocoaError(.fileReadNoPermission) }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" { paths.append(url.path) }
        let live = Set(paths)
        rejectedSources = rejectedSources.filter { live.contains($0.key) }
        var known = try db.files()
        // Existing sources are synchronized first, so an identical newly copied
        // source can be recognized from its persisted content fingerprint.
        paths.sort { (known[$0] == nil ? 1 : 0, $0) < (known[$1] == nil ? 1 : 0, $1) }
        var warnings: [String] = []
        var changed = 0
        for path in paths {
            let relative = String(path.dropFirst(projectsRoot.path.count + 1))
            var attemptedSignature: SessionFileSignature?
            do {
                let before = try SessionFileSignature.read(path)
                attemptedSignature = before
                if rejectedSources[path] == before {
                    warnings.append(URL(fileURLWithPath: path).lastPathComponent)
                    continue
                }
                var state = known[path]
                if state == nil {
                    let matches = known.values.filter { $0.identity == before.identity && !live.contains($0.path) }
                    if matches.count == 1, let moved = matches.first {
                        try db.relocate(moved, relativePath: relative)
                        known.removeValue(forKey: moved.path)
                        state = try db.file(at: path)
                        known[path] = state
                    } else if matches.count > 1 {
                        warnings.append(URL(fileURLWithPath: path).lastPathComponent)
                        continue
                    }
                }
                if let archived = state, archived.rootPath != db.root.path {
                    // A root can be redefined around the same absolute file,
                    // not only moved to another absolute directory.
                    try db.relocate(archived, relativePath: relative)
                    state = try db.file(at: path)
                    known[path] = state
                }
                if let state, state.status != "needs_review", state.parserVersion == Self.parserVersion, state.mtime == before.mtime, state.size == before.size, state.identity == before.identity {
                    if state.status == "missing" { try db.setStatus(id: state.id, status: "present") }
                    continue
                }
                let timezone = state?.timezone.flatMap(TimeZone.init(identifier:)) ?? db.reportingTimezone
                guard let parsed = parseSessionFile(at: path, relativePath: relative, mtime: Double(before.mtime) / 1_000_000_000, timezone: timezone, previousSize: state?.size) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard before == (try SessionFileSignature.read(path)) else {
                    warnings.append(URL(fileURLWithPath: path).lastPathComponent)
                    continue
                }
                if state == nil {
                    if let duplicate = try db.identicalSource(parsed) {
                        log.warning("Ambiguous copied source retained without duplicate import: \(path), existing=\(duplicate.path)")
                        warnings.append(URL(fileURLWithPath: path).lastPathComponent)
                        continue
                    }
                    if let legacy = try db.ambiguousSource(parsed) {
                        try db.setStatus(id: legacy.id, status: "needs_review")
                        known[legacy.path] = try db.file(at: legacy.path)
                        log.warning("Possible relocated source requires review: \(path), archived=\(legacy.path)")
                        warnings.append(URL(fileURLWithPath: path).lastPathComponent)
                        continue
                    }
                }
                if try autoreleasepool(invoking: { try db.synchronize(relativePath: relative, parsed: parsed, signature: before, parserVersion: Self.parserVersion) }) {
                    changed += 1
                    rejectedSources.removeValue(forKey: path)
                    known[path] = try db.file(at: path)
                } else {
                    rejectedSources[path] = before
                    log.warning("Source rewrite rejected; historical data retained: \(path)")
                    warnings.append(URL(fileURLWithPath: path).lastPathComponent)
                }
            } catch let error as DatabaseError {
                // Invalid source data must not prevent other files from syncing.
                guard error.resultCode == .SQLITE_CONSTRAINT else { throw error }
                if let attemptedSignature, attemptedSignature == (try? SessionFileSignature.read(path)) {
                    rejectedSources[path] = attemptedSignature
                }
                warnings.append(URL(fileURLWithPath: path).lastPathComponent)
                log.warning("Source constraint rejected; historical data retained: \(path): \(error.localizedDescription)")
            } catch {
                warnings.append(URL(fileURLWithPath: path).lastPathComponent)
                log.warning("Source not synchronized: \(path): \(error.localizedDescription)")
            }
        }
        if !enumerationFailed {
            for state in known.values where !live.contains(state.path) && state.status != "missing" && state.status != "needs_review" {
                // Confirm absence independently. Enumeration omissions or stat
                // permission errors are not evidence that a source was deleted.
                do { _ = try fm.attributesOfItem(atPath: state.path) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    try db.setStatus(id: state.id, status: "missing")
                } catch { }
            }
        } else { warnings.append("incomplete source directory scan") }
        log.info("refresh: scanned=\(paths.count) changed=\(changed) retained=\(known.count) warnings=\(warnings.count)")
        return warnings.isEmpty ? nil : String(format: NSLocalizedString("usage_storage_sources_paused", bundle: L10n.bundle, comment: "Paused usage sources"), warnings.count)
    }

    func costSummary() async throws -> CostSummary {
        await PricingService.shared.ensureLoaded()

        let db = try database()
        let winners = try db.winners()

        let distinctModels = Set(winners.map { $0.entry.model })
        let priceCache = await PricingService.shared.prices(for: Array(distinctModels))
        return Self.summarize(winners, prices: priceCache, today: Self.dateString(Date(), timezone: db.reportingTimezone))
    }

    static func summarize(_ winners: [UsageDatabase.Winner], prices: [String: LiteLLMModelPricing?], today: String) -> CostSummary {
        // (date, model) → running totals; cost is summed per-row.
        struct Acc {
            var input = 0, output = 0, cw = 0, cr = 0
            var cost: Double = 0
        }
        var bucket: [String: [String: Acc]] = [:]
        var sessionsByDate: [String: Set<String>] = [:]
        for w in winners {
            let e = w.entry
            // ccusage strips `<synthetic>` from modelBreakdowns at aggregation
            // time. These rows are zero-token / zero-cost anyway (compaction
            // events, internal errors), so skipping them changes no numbers —
            // only removes a meaningless entry from the UI's model column.
            if e.model == "<synthetic>" { continue }
            sessionsByDate[e.date, default: []].insert(w.sessionKey)

            // priceCache holds every model seen above; `?? nil` flattens
            // the optional-of-optional for a model with no pricing entry.
            let price = prices[e.model] ?? nil
            let rowCost = price?.cost(
                input: e.input, output: e.output,
                cacheCreate: e.cw, cacheCreate1h: e.cw1h, cacheRead: e.cr,
                isFast: e.speed == "fast"
            ) ?? 0

            var byModel = bucket[e.date] ?? [:]
            var acc = byModel[e.model] ?? Acc()
            acc.input += e.input
            acc.output += e.output
            acc.cw += e.cw
            acc.cr += e.cr
            acc.cost += rowCost
            byModel[e.model] = acc
            bucket[e.date] = byModel
        }

        var dailyCosts: [DailyCost] = []
        for (date, byModel) in bucket {
            var totalCost: Double = 0
            var modelBreakdown: [String: Double] = [:]
            var sumIn = 0, sumOut = 0, sumCW = 0, sumCR = 0
            for (model, acc) in byModel {
                totalCost += acc.cost
                let short = CostParser.shortModelName(model)
                modelBreakdown[short, default: 0] += acc.cost
                sumIn += acc.input; sumOut += acc.output
                sumCW += acc.cw; sumCR += acc.cr
            }
            dailyCosts.append(DailyCost(
                date: date,
                totalCost: totalCost,
                modelBreakdown: modelBreakdown,
                sessionCount: sessionsByDate[date]?.count ?? 0,
                inputTokens: sumIn,
                outputTokens: sumOut,
                cacheWriteTokens: sumCW,
                cacheReadTokens: sumCR
            ))
        }
        dailyCosts.sort { $0.date > $1.date }

        let todayCost = dailyCosts.first(where: { $0.date == today })?.totalCost ?? 0
        log.info("costSummary: \(dailyCosts.count) days, today=$\(String(format: "%.2f", todayCost))")
        return CostSummary(todayCost: todayCost, dailyCosts: dailyCosts)
    }

    func activityStatsToday() throws -> ActivityStats {
        let db = try database()
        return try db.activity(on: Self.dateString(Date(), timezone: db.reportingTimezone))
    }

    static func dateString(_ date: Date, timezone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
