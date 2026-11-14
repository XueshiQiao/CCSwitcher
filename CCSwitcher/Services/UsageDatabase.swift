import Foundation
import Darwin
import GRDB

private let log = FileLog("UsageDatabase")

/// Durable usage history. All business writes are transactional and incremental.
/// Credentials and application preferences deliberately remain outside this database.
final class UsageDatabase: Sendable {
    enum StorageError: LocalizedError {
        case newerDatabase, invalidRecord(String)
        var errorDescription: String? {
            switch self {
            case .newerDatabase: return String(localized: "usage_storage_newer", bundle: L10n.bundle)
            case .invalidRecord(let reason): return String(format: NSLocalizedString("usage_storage_write_failed", bundle: L10n.bundle, comment: "Usage write failure"), reason)
            }
        }
    }

    struct FileState: Sendable {
        let id: Int64
        let rootPath: String
        let path: String
        let mtime: Int64?
        let size: Int64?
        let parserVersion: Int
        let status: String
        let identity: String?
        let timezone: String?
    }

    struct Winner: Sendable {
        let entry: CachedEntryV2
        let sessionKey: String
    }

    private let pool: DatabasePool
    let reportingTimezone: TimeZone
    let root: URL

    init(url: URL, root: URL, legacyURL: URL?, timezone: TimeZone) throws {
        self.root = canonicalUsageSourceURL(root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.qos = .utility
        let pool = try DatabasePool(path: url.path, configuration: config)
        let migrator = Self.makeMigrator(root: self.root, legacyURL: legacyURL, timezone: timezone)
        if try pool.read({ try migrator.hasBeenSuperseded($0) }) { throw StorageError.newerDatabase }
        // DatabasePool sets NORMAL while entering WAL. Set FULL on the writer
        // afterwards, outside a transaction, rather than in prepareDatabase.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            guard try Int.fetchOne(db, sql: "PRAGMA synchronous") == 2 else {
                throw StorageError.invalidRecord("FULL synchronous mode is unavailable")
            }
        }
        if try pool.read({ try !migrator.hasCompletedMigrations($0) }),
           try pool.read({ db in
               guard try db.tableExists("session_files") else { return false }
               return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_files")! > 0
           }) {
            let backupURL = url.deletingLastPathComponent().appendingPathComponent("usage-before-migration-\(UUID().uuidString).sqlite")
            let backup = try DatabaseQueue(path: backupURL.path)
            try pool.backup(to: backup)
        }
        try migrator.migrate(pool)
        self.pool = pool
        let savedZone: String? = try pool.read { db in
            for row in try Row.fetchAll(db, sql: "SELECT extensions_json FROM session_files ORDER BY id") {
                let raw: String = row["extensions_json"]
                if let zone = try Self.object(raw)["reporting_timezone"] as? String { return zone }
            }
            return nil
        }
        self.reportingTimezone = savedZone.flatMap(TimeZone.init(identifier:)) ?? timezone
    }

    private static func makeMigrator(root: URL, legacyURL: URL?, timezone: TimeZone) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial_usage_schema") { db in
            try db.execute(sql: """
                CREATE TABLE session_files (
                    id INTEGER PRIMARY KEY,
                    provider TEXT NOT NULL,
                    root_path TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    project_key TEXT NOT NULL,
                    session_id TEXT,
                    is_sidechain INTEGER NOT NULL DEFAULT 0 CHECK (is_sidechain IN (0,1)),
                    source_mtime_ns INTEGER,
                    source_size_bytes INTEGER,
                    earliest_timestamp_us INTEGER,
                    parser_version INTEGER NOT NULL,
                    statistics_timezone TEXT,
                    source_status TEXT NOT NULL CHECK (source_status IN ('present','missing','needs_review')),
                    activity_by_date_json TEXT NOT NULL CHECK (json_valid(activity_by_date_json) AND json_type(activity_by_date_json) = 'object'),
                    extensions_json TEXT NOT NULL CHECK (json_valid(extensions_json) AND json_type(extensions_json) = 'object'),
                    created_at_us INTEGER NOT NULL,
                    updated_at_us INTEGER NOT NULL,
                    UNIQUE(provider, root_path, relative_path)
                );
                CREATE TABLE usage_records (
                    id INTEGER PRIMARY KEY,
                    file_id INTEGER NOT NULL REFERENCES session_files(id) ON DELETE RESTRICT,
                    record_key TEXT NOT NULL,
                    dedup_key TEXT,
                    source_order INTEGER NOT NULL,
                    timestamp_us INTEGER,
                    local_date TEXT NOT NULL,
                    model TEXT NOT NULL,
                    speed TEXT CHECK (speed IS NULL OR speed IN ('standard','fast')),
                    input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
                    output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
                    cache_creation_tokens INTEGER NOT NULL CHECK (cache_creation_tokens >= 0),
                    cache_creation_1h_tokens INTEGER NOT NULL CHECK (cache_creation_1h_tokens >= 0),
                    cache_read_tokens INTEGER NOT NULL CHECK (cache_read_tokens >= 0),
                    extensions_json TEXT NOT NULL CHECK (json_valid(extensions_json) AND json_type(extensions_json) = 'object'),
                    created_at_us INTEGER NOT NULL,
                    updated_at_us INTEGER NOT NULL,
                    UNIQUE(file_id, record_key)
                );
                CREATE INDEX usage_records_dedup ON usage_records(dedup_key, output_tokens DESC);
                CREATE INDEX usage_records_date ON usage_records(local_date);
                """)
        }
        // One-time DATA migration: GRDB records this receipt even when the
        // source is absent or empty. Clearing business rows never resurrects it.
        migrator.registerMigration("v2_import_legacy_json_v3") { db in
            guard let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) else { return }
            // An unreadable cache is treated like a missing one: the scan of
            // the JSONL sources rebuilds what still exists.
            let data: Data
            do { data = try Data(contentsOf: legacyURL) }
            catch {
                log.warning("Legacy import skipped: cache cannot be read (\(error.localizedDescription))")
                return
            }
            try LegacyUsageImportV3.run(data: data, root: root, timezone: timezone, db: db)
        }
        return migrator
    }

    func files() throws -> [String: FileState] {
        try pool.read { db in
            var result: [String: FileState] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id,root_path,relative_path,source_mtime_ns,source_size_bytes,parser_version,source_status,extensions_json,statistics_timezone FROM session_files WHERE provider = 'claude'") {
                let relative: String = row["relative_path"]
                let sourceRoot: String = row["root_path"]
                let path = URL(fileURLWithPath: sourceRoot).appendingPathComponent(relative).path
                let raw: String = row["extensions_json"]
                result[path] = FileState(id: row["id"], rootPath: row["root_path"], path: path, mtime: row["source_mtime_ns"], size: row["source_size_bytes"], parserVersion: row["parser_version"], status: row["source_status"], identity: try Self.sourceIdentity(raw), timezone: row["statistics_timezone"])
            }
            return result
        }
    }

    func file(at sourcePath: String) throws -> FileState? {
        let path = canonicalUsageSourceURL(URL(fileURLWithPath: sourcePath)).path
        return try pool.read { db in
            let columns = "SELECT id,root_path,source_mtime_ns,source_size_bytes,parser_version,source_status,extensions_json,statistics_timezone FROM session_files WHERE provider='claude' AND "
            var row: Row?
            if path.hasPrefix(root.path + "/") {
                let relative = String(path.dropFirst(root.path.count + 1))
                row = try Row.fetchOne(db, sql: columns + "root_path=? AND relative_path=?", arguments: [root.path, relative])
            }
            if row == nil {
                row = try Row.fetchOne(db, sql: columns + "root_path || '/' || relative_path=?", arguments: [path])
            }
            guard let row else { return nil }
            let raw: String = row["extensions_json"]
            return FileState(id: row["id"], rootPath: row["root_path"], path: path, mtime: row["source_mtime_ns"], size: row["source_size_bytes"], parserVersion: row["parser_version"], status: row["source_status"], identity: try Self.sourceIdentity(raw), timezone: row["statistics_timezone"])
        }
    }

    /// Legacy imports and copies across filesystems may lack a matching identity.
    /// A matching archived contribution warrants review; online sources may resume
    /// into new files and must not block those files from being synchronized.
    func ambiguousSource(_ parsed: CachedFileV2) throws -> FileState? {
        let path: String? = try pool.read { db in
            let candidates = try Row.fetchAll(db, sql: "SELECT * FROM session_files WHERE provider='claude'")
            for candidate in candidates {
                guard (candidate["session_id"] as String?) == parsed.sessionId,
                      (candidate["is_sidechain"] as Bool) == parsed.isSidechain else { continue }
                let id: Int64 = candidate["id"]
                let oldPath = URL(fileURLWithPath: candidate["root_path"]).appendingPathComponent(candidate["relative_path"] as String).path
                guard !FileManager.default.fileExists(atPath: oldPath) else { continue }
                let old = try Row.fetchAll(db, sql: "SELECT * FROM usage_records WHERE file_id=? ORDER BY source_order", arguments: [id])
                guard !old.isEmpty || !parsed.activityByDate.isEmpty else { continue }
                let incomingHashes = Set(parsed.entries.compactMap(\.hash))
                let sharedID = old.contains { row in
                    let hash: String? = row["dedup_key"]
                    return hash.map(incomingHashes.contains) ?? false
                }
                let anonymousOld = old.filter { ($0["dedup_key"] as String?) == nil }
                let anonymousNew = parsed.entries.filter { $0.hash == nil }
                let anonymousPrefix = !anonymousOld.isEmpty && anonymousOld.count <= anonymousNew.count && zip(anonymousOld, anonymousNew).allSatisfy { row, entry in
                    (row["local_date"] as String) == entry.date && (row["model"] as String) == entry.model
                        && (row["speed"] as String?) == entry.speed && (row["input_tokens"] as Int) == entry.input
                        && (row["output_tokens"] as Int) == entry.output && (row["cache_creation_tokens"] as Int) == entry.cw
                        && (row["cache_creation_1h_tokens"] as Int) == entry.cw1h && (row["cache_read_tokens"] as Int) == entry.cr
                }
                let previous = try Self.activityDays(candidate["activity_by_date_json"])
                let activityOverlap = old.isEmpty && !previous.isEmpty && previous.allSatisfy { date, value in
                    guard let oldDay = value as? [String: Any], let newDay = parsed.activityByDate[date] else { return false }
                    return newDay.turns >= (oldDay["turns"] as? Int ?? 0)
                        && newDay.activeMinutes >= (oldDay["active_minutes"] as? Int ?? 0)
                        && newDay.linesWritten >= (oldDay["lines_written"] as? Int ?? 0)
                }
                // A legacy snapshot predates the upgrade and can be a prefix
                // of a renamed, still-growing file. Exact equality is too weak.
                guard sharedID || anonymousPrefix || activityOverlap else { continue }
                let relative: String = candidate["relative_path"]
                let sourceRoot: String = candidate["root_path"]
                return URL(fileURLWithPath: sourceRoot).appendingPathComponent(relative).path
            }
            return nil
        }
        return try path.flatMap { try file(at: $0) }
    }

    /// Atomic relocation keeps anonymous costs and activity from being counted twice.
    func relocate(_ file: FileState, relativePath: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE session_files SET root_path = ?, relative_path = ?, project_key = ?, is_sidechain = ?, source_status = CASE WHEN source_status='needs_review' THEN source_status ELSE 'present' END, updated_at_us = ? WHERE id = ?", arguments: [root.path, relativePath, relativePath.split(separator: "/").first.map(String.init) ?? "unknown", relativePath.contains("/subagents/"), Self.now(), file.id])
        }
    }

    func identicalSource(_ parsed: CachedFileV2) throws -> FileState? {
        guard let hash = parsed.contentHash else { return nil }
        let matches = try pool.read { db in
            try String.fetchAll(db, sql: "SELECT root_path || '/' || relative_path FROM session_files WHERE provider='claude' AND json_extract(extensions_json, '$.source_sha256')=? LIMIT 1", arguments: [hash])
        }
        guard let path = matches.first else { return nil }
        return try file(at: path)
    }

    func setStatus(id: Int64, status: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE session_files SET source_status = ?, updated_at_us = ? WHERE id = ? AND source_status IS NOT ?", arguments: [status, Self.now(), id, status])
        }
    }

    /// Returns false for destructive or ambiguous source changes. A rejected
    /// snapshot changes only its status, never the stored historical content.
    func synchronize(relativePath: String, parsed: CachedFileV2, signature: SessionFileSignature, parserVersion: Int) throws -> Bool {
        try pool.write { db in
            let prior = try Row.fetchOne(db, sql: "SELECT * FROM session_files WHERE provider = 'claude' AND root_path = ? AND relative_path = ?", arguments: [root.path, relativePath])
            var anonymousMoves: [(id: Int64, key: String)] = []
            if let prior {
                let id: Int64 = prior["id"]
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM usage_records WHERE file_id = ? ORDER BY source_order", arguments: [id])
                var existing = Dictionary(uniqueKeysWithValues: rows.map { (($0["record_key"] as String), $0) })
                let incoming = Self.keyed(parsed.entries)
                let oldSize: Int64? = prior["source_size_bytes"]
                let oldExtras = try Self.object(prior["extensions_json"])
                let oldIdentity = (oldExtras["source_identity"] as? String).map(SessionFileSignature.normalizedIdentity)
                let oldHash = oldExtras["source_sha256"] as? String
                let oldZone: String? = prior["statistics_timezone"]
                let oldSession: String? = prior["session_id"]
                let oldDays = try Self.activityDays(prior["activity_by_date_json"])
                // V2 recovers rows that V1 accidentally split on Unicode separators.
                // Verify existing bytes for SQLite sources. Legacy JSON has no
                // digest/UTC times: match every known value and retain the other
                // legacy safety checks below. Both require a unique alignment.
                var ambiguousAnonymousUpgrade = false
                let legacyUpgrade = (prior["parser_version"] as Int) == 0 && oldExtras["legacy_fields"] != nil
                let verifiedUpgrade = (prior["parser_version"] as Int) == 1
                    && oldHash != nil && oldHash == parsed.prefixHash && oldIdentity == signature.identity
                if parserVersion == 2, legacyUpgrade || verifiedUpgrade {
                    let anonymous = rows.filter { ($0["dedup_key"] as String?) == nil }
                    let candidates = incoming.filter { $0.entry.hash == nil }
                    if candidates.count > anonymous.count {
                        let oldEntries = try anonymous.map(Self.entry)
                        var first: [Int] = [], last: [Int] = []
                        var cursor = 0
                        for old in oldEntries {
                            while cursor < candidates.count, !Self.sameAnonymousEntry(old, candidates[cursor].entry, allowUnknownTimestamp: legacyUpgrade) { cursor += 1 }
                            guard cursor < candidates.count else { break }
                            first.append(cursor); cursor += 1
                        }
                        cursor = candidates.count - 1
                        for old in oldEntries.reversed() {
                            while cursor >= 0, !Self.sameAnonymousEntry(old, candidates[cursor].entry, allowUnknownTimestamp: legacyUpgrade) { cursor -= 1 }
                            guard cursor >= 0 else { break }
                            last.append(cursor); cursor -= 1
                        }
                        if first.count == anonymous.count, first == Array(last.reversed()) {
                            for row in anonymous { existing.removeValue(forKey: row["record_key"]) }
                            for (row, index) in zip(anonymous, first) {
                                let key = candidates[index].key
                                existing[key] = row
                                if key != (row["record_key"] as String) { anonymousMoves.append((row["id"], key)) }
                            }
                        } else { ambiguousAnonymousUpgrade = true }
                    }
                }
                // Split into typed parts: as one expression the Release build's
                // type checker gives up ("unable to type-check ... in reasonable time").
                let shrank: Bool = oldSize.map { signature.size < $0 } ?? false
                let identityChanged: Bool = oldIdentity.map { $0 != signature.identity } ?? false
                let prefixChanged: Bool = oldHash.map { $0 != parsed.prefixHash } ?? false
                let sessionChanged: Bool = oldSession != nil && parsed.sessionId != oldSession
                let lostRecords: Bool = !Set(existing.keys).isSubset(of: Set(incoming.map(\.key)))
                let lostDays: Bool = !Set(oldDays.keys).isSubset(of: Set(parsed.activityByDate.keys))
                let activityShrank: Bool = oldHash == nil && oldDays.contains { (date: String, raw: Any) -> Bool in
                    guard let old = raw as? [String: Any], let new = parsed.activityByDate[date] else { return true }
                    let oldTurns: Int = old["turns"] as? Int ?? 0
                    let oldMinutes: Int = old["active_minutes"] as? Int ?? 0
                    let oldLines: Int = old["lines_written"] as? Int ?? 0
                    if new.turns < oldTurns || new.activeMinutes < oldMinutes || new.linesWritten < oldLines { return true }
                    let oldTools: [String: Int] = old["tool_counts"] as? [String: Int] ?? [:]
                    for (tool, count) in oldTools where new.toolCounts[tool, default: 0] < count { return true }
                    let oldModels: [String: Int] = old["model_counts"] as? [String: Int] ?? [:]
                    for (model, count) in oldModels where new.modelCounts[model, default: 0] < count { return true }
                    return false
                }
                let recordConflicts: Bool = incoming.contains { pair -> Bool in
                    guard let old = existing[pair.key] else { return false }
                    let oldInput: Int = old["input_tokens"]
                    let oldOutput: Int = old["output_tokens"]
                    let oldCacheWrite: Int = old["cache_creation_tokens"]
                    let oldCacheWrite1h: Int = old["cache_creation_1h_tokens"]
                    let oldCacheRead: Int = old["cache_read_tokens"]
                    let oldModel: String = old["model"]
                    let oldSpeed: String? = old["speed"]
                    let oldDate: String = old["local_date"]
                    if pair.entry.output < oldOutput { return true }
                    let sameTokens: Bool = pair.entry.input == oldInput && pair.entry.cw == oldCacheWrite
                        && pair.entry.cw1h == oldCacheWrite1h && pair.entry.cr == oldCacheRead
                    let sameLabels: Bool = pair.entry.model == oldModel && pair.entry.speed == oldSpeed
                    if !sameTokens || !sameLabels { return true }
                    if oldZone == nil, pair.entry.date != oldDate { return true }
                    // Without IDs, ordinal alone is not evidence for changing
                    // an already-stored row; require the original usage match.
                    if pair.entry.hash == nil {
                        return pair.entry.output != oldOutput || pair.entry.date != oldDate
                    }
                    return false
                }
                let unsafe: Bool = ambiguousAnonymousUpgrade || shrank || identityChanged || prefixChanged
                    || sessionChanged || lostRecords || lostDays || activityShrank || recordConflicts
                if unsafe {
                    try db.execute(sql: "UPDATE session_files SET source_status = 'needs_review', updated_at_us = ? WHERE id = ? AND source_status != 'needs_review'", arguments: [Self.now(), id])
                    return false
                }
            }
            // Temporary keys avoid UNIQUE collisions while shifting ordinals.
            // This and the upserts below are one transaction; IDs and extension data survive.
            for move in anonymousMoves {
                try db.execute(sql: "UPDATE usage_records SET record_key=? WHERE id=?", arguments: ["upgrade-v2:\(move.id)",move.id])
            }
            for move in anonymousMoves {
                try db.execute(sql: "UPDATE usage_records SET record_key=? WHERE id=?", arguments: [move.key,move.id])
            }
            let id = try Self.saveFile(db, root: root, relativePath: relativePath, parsed: parsed, signature: signature, parserVersion: parserVersion, timezone: reportingTimezone)
            let oldRows = try Row.fetchAll(db, sql: "SELECT record_key, extensions_json FROM usage_records WHERE file_id = ?", arguments: [id])
            let oldExtensions = Dictionary(uniqueKeysWithValues: oldRows.map { (($0["record_key"] as String), ($0["extensions_json"] as String)) })
            for pair in Self.keyed(parsed.entries) {
                try Self.saveEntry(db, fileID: id, key: pair.key, order: pair.order, entry: pair.entry, priorExtensions: oldExtensions[pair.key])
            }
            return true
        }
    }

    static let winnerSQL = """
                SELECT u.*, COALESCE(f.session_id, f.root_path || '/' || f.relative_path) AS session_key
                FROM usage_records u JOIN session_files f ON f.id = u.file_id
                WHERE u.model != '<synthetic>' AND (
                    u.dedup_key IS NULL OR NOT EXISTS (
                        SELECT 1 FROM usage_records b JOIN session_files bf ON bf.id=b.file_id
                        WHERE b.dedup_key=u.dedup_key AND bf.provider=f.provider AND (
                            b.output_tokens > u.output_tokens OR (b.output_tokens=u.output_tokens AND
                                (bf.earliest_timestamp_us IS NULL, COALESCE(bf.earliest_timestamp_us,0),
                                 bf.root_path || '/' || bf.relative_path COLLATE BINARY, b.source_order)
                                <
                                (f.earliest_timestamp_us IS NULL, COALESCE(f.earliest_timestamp_us,0),
                                 f.root_path || '/' || f.relative_path COLLATE BINARY, u.source_order)
                            )
                        )
                    )
                )
                """

    func winners() throws -> [Winner] {
        try pool.read { db in
            try Row.fetchAll(db, sql: Self.winnerSQL).map { row in
                Winner(entry: try Self.entry(row), sessionKey: row["session_key"])
            }
        }
    }

    func activity(on date: String) throws -> ActivityStats {
        try pool.read { db in
            var result = ActivityStats()
            for row in try Row.fetchAll(db, sql: "SELECT activity_by_date_json FROM session_files WHERE is_sidechain = 0") {
                guard let day = try Self.activityDays(row["activity_by_date_json"])[date] as? [String: Any] else { continue }
                result.conversationTurns += day["turns"] as? Int ?? 0
                result.activeCodingMinutes += day["active_minutes"] as? Int ?? 0
                result.linesWritten += day["lines_written"] as? Int ?? 0
                for (key, value) in day["tool_counts"] as? [String: Int] ?? [:] { result.toolUsage[key, default: 0] += value }
                for (key, value) in day["model_counts"] as? [String: Int] ?? [:] { result.modelUsage[key, default: 0] += value }
            }
            return result
        }
    }

    // Only this internal access is used by isolated persistence tests.
    func read<T>(_ body: (Database) throws -> T) throws -> T { try pool.read(body) }

    func testingWrite(_ body: (Database) throws -> Void) throws { try pool.write(body) }
    func testingCheckpoint() throws { _ = try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) } }
    func totalChanges() -> Int { pool.writeWithoutTransaction { $0.totalChangesCount } }
    func writerSynchronousMode() throws -> Int { try pool.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA synchronous")! } }

    private static func sameAnonymousEntry(_ a: CachedEntryV2, _ b: CachedEntryV2, allowUnknownTimestamp: Bool) -> Bool {
        a.hash == nil && b.hash == nil
            && ((allowUnknownTimestamp && a.timestampUnix == nil) || microseconds(a.timestampUnix) == microseconds(b.timestampUnix))
            && a.date == b.date && a.hour == b.hour && a.model == b.model && a.speed == b.speed
            && a.input == b.input && a.output == b.output && a.cw == b.cw && a.cw1h == b.cw1h && a.cr == b.cr
            && a.costUSDRow == b.costUSDRow && a.tools == b.tools && a.linesWritten == b.linesWritten
    }

    static func keyed(_ entries: [CachedEntryV2]) -> [(key: String, order: Int, entry: CachedEntryV2)] {
        var anonymous = 0
        return entries.enumerated().map { order, entry in
            let key: String
            if let hash = entry.hash { key = "id:" + hash }
            else { key = "anonymous:\(anonymous)"; anonymous += 1 }
            return (key, order, entry)
        }
    }

    private static func saveFile(_ db: Database, root: URL, relativePath: String, parsed: CachedFileV2, signature: SessionFileSignature?, parserVersion: Int, timezone: TimeZone) throws -> Int64 {
        let prior = try Row.fetchOne(db, sql: "SELECT * FROM session_files WHERE provider = 'claude' AND root_path = ? AND relative_path = ?", arguments: [root.path, relativePath])
        var extras = try prior.map { try object($0["extensions_json"]) } ?? ["_v": 1]
        extras["reporting_timezone"] = timezone.identifier
        if let hash = parsed.contentHash { extras["source_sha256"] = hash }
        if let signature { extras["source_identity"] = signature.identity }
        let activity = try activityJSON(parsed.activityByDate, previous: prior?["activity_by_date_json"])
        let earliest = microseconds(parsed.earliestTimestampUnix)
        let stamp = now()
        try db.execute(sql: """
            INSERT INTO session_files (provider,root_path,relative_path,project_key,session_id,is_sidechain,source_mtime_ns,source_size_bytes,earliest_timestamp_us,parser_version,statistics_timezone,source_status,activity_by_date_json,extensions_json,created_at_us,updated_at_us)
            VALUES ('claude',?,?,?,?,?,?,?,?,?,?,'present',?,?,?,?)
            ON CONFLICT(provider,root_path,relative_path) DO UPDATE SET
                project_key=excluded.project_key,session_id=excluded.session_id,is_sidechain=excluded.is_sidechain,
                source_mtime_ns=excluded.source_mtime_ns,source_size_bytes=excluded.source_size_bytes,
                earliest_timestamp_us=excluded.earliest_timestamp_us,parser_version=excluded.parser_version,
                statistics_timezone=excluded.statistics_timezone,source_status=excluded.source_status,
                activity_by_date_json=excluded.activity_by_date_json,extensions_json=excluded.extensions_json,updated_at_us=excluded.updated_at_us
            """, arguments: [root.path, relativePath, parsed.project, parsed.sessionId, parsed.isSidechain, signature?.mtime, signature?.size, earliest, parserVersion, signature == nil ? nil : timezone.identifier, activity, try json(extras), stamp, stamp])
        return try Int64.fetchOne(db, sql: "SELECT id FROM session_files WHERE provider='claude' AND root_path=? AND relative_path=?", arguments: [root.path, relativePath])!
    }

    private static func saveEntry(_ db: Database, fileID: Int64, key: String, order: Int, entry: CachedEntryV2, priorExtensions: String?) throws {
        var extras = try priorExtensions.map(object) ?? ["_v": 1]
        extras["hour"] = entry.hour
        extras["tools"] = entry.tools
        extras["linesWritten"] = entry.linesWritten
        if let cost = entry.costUSDRow { extras["costUSDRow"] = cost }
        let stamp = now()
        try db.execute(sql: """
            INSERT INTO usage_records (file_id,record_key,dedup_key,source_order,timestamp_us,local_date,model,speed,input_tokens,output_tokens,cache_creation_tokens,cache_creation_1h_tokens,cache_read_tokens,extensions_json,created_at_us,updated_at_us)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(file_id,record_key) DO UPDATE SET
                dedup_key=excluded.dedup_key,source_order=excluded.source_order,timestamp_us=excluded.timestamp_us,
                local_date=excluded.local_date,model=excluded.model,speed=excluded.speed,input_tokens=excluded.input_tokens,
                output_tokens=excluded.output_tokens,cache_creation_tokens=excluded.cache_creation_tokens,
                cache_creation_1h_tokens=excluded.cache_creation_1h_tokens,cache_read_tokens=excluded.cache_read_tokens,
                extensions_json=excluded.extensions_json,updated_at_us=excluded.updated_at_us
            WHERE dedup_key IS NOT excluded.dedup_key OR source_order IS NOT excluded.source_order
                OR timestamp_us IS NOT excluded.timestamp_us OR local_date IS NOT excluded.local_date
                OR model IS NOT excluded.model OR speed IS NOT excluded.speed OR input_tokens IS NOT excluded.input_tokens
                OR output_tokens IS NOT excluded.output_tokens OR cache_creation_tokens IS NOT excluded.cache_creation_tokens
                OR cache_creation_1h_tokens IS NOT excluded.cache_creation_1h_tokens OR cache_read_tokens IS NOT excluded.cache_read_tokens
                OR extensions_json IS NOT excluded.extensions_json
            """, arguments: [fileID,key,entry.hash,order,microseconds(entry.timestampUnix),entry.date,entry.model,entry.speed,entry.input,entry.output,entry.cw,entry.cw1h,entry.cr,try json(extras),stamp,stamp])
    }

    private static func entry(_ row: Row) throws -> CachedEntryV2 {
        let extras = try object(row["extensions_json"])
        let timestamp: Int64? = row["timestamp_us"]
        return CachedEntryV2(timestampUnix: timestamp.map { Double($0) / 1_000_000 }, hash: row["dedup_key"], date: row["local_date"], hour: extras["hour"] as? Int ?? 0, model: row["model"], speed: row["speed"], input: row["input_tokens"], output: row["output_tokens"], cw: row["cache_creation_tokens"], cw1h: row["cache_creation_1h_tokens"], cr: row["cache_read_tokens"], costUSDRow: extras["costUSDRow"] as? Double, tools: extras["tools"] as? [String: Int] ?? [:], linesWritten: extras["linesWritten"] as? Int ?? 0)
    }

    private static func activityJSON(_ days: [String: ActivityDayContributionV2], previous: String?) throws -> String {
        var envelope = try previous.map(object) ?? ["_v": 1]
        var stored = envelope["days"] as? [String: Any] ?? [:]
        for (date, day) in days {
            var value = stored[date] as? [String: Any] ?? [:]
            value["turns"] = day.turns
            value["active_minutes"] = day.activeMinutes
            value["lines_written"] = day.linesWritten
            value["tool_counts"] = day.toolCounts
            value["model_counts"] = day.modelCounts
            stored[date] = value
        }
        envelope["days"] = stored
        return try json(envelope)
    }

    private static func activityDays(_ raw: String) throws -> [String: Any] { try object(raw)["days"] as? [String: Any] ?? [:] }
    private static func sourceIdentity(_ raw: String) throws -> String? {
        (try object(raw)["source_identity"] as? String).map(SessionFileSignature.normalizedIdentity)
    }
    private static func object(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StorageError.invalidRecord("expected a JSON object") }
        return value
    }
    private static func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000) }
    private static func microseconds(_ seconds: Double?) -> Int64? {
        guard let seconds, seconds.isFinite, abs(seconds) < Double(Int64.max / 1_000_000) else { return nil }
        return Int64((seconds * 1_000_000).rounded())
    }
}

/// Frozen v3 decoder and data migration. Do not change this accepted legacy shape
/// when the live parser gains fields; add a new schema/data migration instead.
private enum LegacyUsageImportV3 {
    struct Entry: Decodable {
        let hash: String?, date: String, hour: Int, model: String, speed: String?
        let input: Int, output: Int, cw: Int, cw1h: Int, cr: Int
        let costUSDRow: Double?
        let tools: [String: Int]
        let linesWritten: Int

    }
    struct Day: Decodable {
        let turns: Int, activeMinutes: Int, linesWritten: Int
        let toolCounts: [String: Int], modelCounts: [String: Int]

    }
    struct File: Decodable {
        let mtimeUnix: Double, earliestTimestampUnix: Double
        let project: String, sessionId: String?
        let isSidechain: Bool
        let entries: [Entry]
        let activityByDate: [String: Day]

    }
    struct Envelope: Decodable { let version: Int; let files: [String: File] }
    private static func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func run(data: Data, root: URL, timezone: TimeZone, db: Database) throws {
        // The old app discarded a cache it could not decode or whose version
        // differed, so its user never saw that data. Do the same rather than
        // failing on every launch; the file stays on disk untouched.
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch {
            log.warning("Legacy import skipped: cache cannot be decoded (\(error.localizedDescription))")
            return
        }
        guard envelope.version == 3 else {
            log.warning("Legacy import skipped: unsupported format version \(envelope.version)")
            return
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rawFiles = raw["files"] as? [String: [String: Any]] else {
            log.warning("Legacy import skipped: missing files map")
            return
        }
        let stamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
        var outsideRoot = 0
        defer { if outsideRoot > 0 { log.warning("Legacy import skipped \(outsideRoot) sources outside \(root.path)") } }
        for (originalPath, file) in envelope.files.sorted(by: { $0.key < $1.key }) {
            let path = canonicalUsageSourceURL(URL(fileURLWithPath: originalPath)).path
            // A renamed home folder leaves sources under another root; the scan
            // of the current root picks up whichever of those files still exist.
            guard path.hasPrefix(root.path + "/") else { outsideRoot += 1; continue }
            let relative = String(path.dropFirst(root.path.count + 1))
            let rawFile = rawFiles[originalPath] ?? [:]
            let knownFile: Set<String> = ["entries","activityByDate","mtimeUnix","earliestTimestampUnix","project","sessionId","isSidechain"]
            let extras: [String: Any] = ["_v":1,"reporting_timezone":timezone.identifier,"legacy_mtime_unix":file.mtimeUnix,"legacy_fields":rawFile.filter { !knownFile.contains($0.key) }]
            var days: [String: Any] = [:]
            let rawDays = rawFile["activityByDate"] as? [String: [String: Any]] ?? [:]
            let knownDay: Set<String> = ["turns","activeMinutes","linesWritten","toolCounts","modelCounts"]
            for (date, day) in file.activityByDate {
                var value = (rawDays[date] ?? [:]).filter { !knownDay.contains($0.key) }
                value["turns"] = day.turns
                value["active_minutes"] = day.activeMinutes
                value["lines_written"] = day.linesWritten
                value["tool_counts"] = day.toolCounts
                value["model_counts"] = day.modelCounts
                days[date] = value
            }
            let earliest: Int64? = file.earliestTimestampUnix.isFinite && abs(file.earliestTimestampUnix) < Double(Int64.max / 1_000_000) ? Int64((file.earliestTimestampUnix * 1_000_000).rounded()) : nil
            // Frozen v1 SQL: this data migration must never use live upsert
            // helpers that may target columns introduced by later migrations.
            try db.execute(sql: """
                INSERT INTO session_files(provider,root_path,relative_path,project_key,session_id,is_sidechain,
                    source_mtime_ns,source_size_bytes,earliest_timestamp_us,parser_version,statistics_timezone,
                    source_status,activity_by_date_json,extensions_json,created_at_us,updated_at_us)
                VALUES ('claude',?,?,?,?,?,NULL,NULL,?,0,NULL,'present',?,?,?,?)
                ON CONFLICT(provider,root_path,relative_path) DO NOTHING
                """, arguments: [root.path,relative,file.project,file.sessionId,file.isSidechain,earliest,try encode(["_v":1,"days":days]),try encode(extras),stamp,stamp])
            // Two cache paths can canonicalize to the same file. The first one wins;
            // lastInsertedRowID would still point at an earlier file here.
            guard db.changesCount > 0 else {
                log.warning("Legacy import skipped duplicate source after canonicalization: \(path)")
                continue
            }
            let fileID = db.lastInsertedRowID
            let rawEntries = rawFile["entries"] as? [[String: Any]] ?? []
            var anonymous = 0
            for (order, entry) in file.entries.enumerated() {
                let key: String
                if let hash = entry.hash { key = "id:" + hash }
                else { key = "anonymous:\(anonymous)"; anonymous += 1 }
                let known: Set<String> = ["hash","date","model","speed","input","output","cw","cw1h","cr"]
                var extra = (rawEntries.indices.contains(order) ? rawEntries[order] : [:]).filter { !known.contains($0.key) }
                extra["_v"] = 1
                try db.execute(sql: """
                    INSERT INTO usage_records(file_id,record_key,dedup_key,source_order,timestamp_us,local_date,
                        model,speed,input_tokens,output_tokens,cache_creation_tokens,cache_creation_1h_tokens,
                        cache_read_tokens,extensions_json,created_at_us,updated_at_us)
                    VALUES (?,?,?,?,NULL,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(file_id,record_key) DO UPDATE SET
                        dedup_key=excluded.dedup_key,source_order=excluded.source_order,local_date=excluded.local_date,
                        model=excluded.model,speed=excluded.speed,input_tokens=excluded.input_tokens,
                        output_tokens=excluded.output_tokens,cache_creation_tokens=excluded.cache_creation_tokens,
                        cache_creation_1h_tokens=excluded.cache_creation_1h_tokens,cache_read_tokens=excluded.cache_read_tokens,
                        extensions_json=excluded.extensions_json
                    WHERE excluded.output_tokens > usage_records.output_tokens
                    """, arguments: [fileID,key,entry.hash,order,entry.date,entry.model,entry.speed,entry.input,entry.output,entry.cw,entry.cw1h,entry.cr,try encode(extra),stamp,stamp])
            }
        }

    }
}

struct SessionFileSignature: Equatable, Sendable {
    let mtime: Int64
    let size: Int64
    let identity: String

    static func read(_ path: String) throws -> SessionFileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw UsageDatabase.StorageError.invalidRecord("could not read source file identity")
        }
        let birth = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return SessionFileSignature(mtime: Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded()), size: size.int64Value, identity: "\(inode):\(birth)")
    }

    static func normalizedIdentity(_ stored: String) -> String {
        let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 ? parts.dropFirst().joined(separator: ":") : stored
    }
}

/// Foundation intentionally preserves some /var aliases while its enumerator
/// returns /private/var. POSIX realpath gives a consistent identity boundary.
/// Missing historical files resolve their nearest existing ancestor instead.
func canonicalUsageSourceURL(_ url: URL) -> URL {
    var ancestor = url.standardizedFileURL
    var suffix: [String] = []
    while true {
        if let resolved = ancestor.path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            var result = URL(fileURLWithPath: String(cString: resolved))
            for component in suffix.reversed() { result.appendPathComponent(component) }
            return result
        }
        let parent = ancestor.deletingLastPathComponent()
        guard parent.path != ancestor.path else { return url.standardizedFileURL }
        suffix.append(ancestor.lastPathComponent)
        ancestor = parent
    }
}
