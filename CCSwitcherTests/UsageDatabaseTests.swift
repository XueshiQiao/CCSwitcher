import XCTest
import Foundation
import GRDB

final class UsageDatabaseTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("projects") }
    private var databaseURL: URL { directory.appendingPathComponent("usage.sqlite") }
    private let utc = TimeZone(secondsFromGMT: 0)!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccswitcher-sqlite-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func database(legacy: URL? = nil) throws -> UsageDatabase {
        try UsageDatabase(url: databaseURL, root: root, legacyURL: legacy, timezone: utc)
    }

    private func entry(_ hash: String? = "message:request", output: Int = 10, date: String = "2026-10-25", input: Int = 3) -> CachedEntryV2 {
        CachedEntryV2(timestampUnix: 1_792_886_400, hash: hash, date: date, hour: 0, model: "claude-fable-5-1", speed: "standard", input: input, output: output, cw: 100, cw1h: 20, cr: 200, costUSDRow: nil, tools: ["Bash": 1], linesWritten: 2)
    }

    private func file(_ entries: [CachedEntryV2], earliest: Double = 10, sidechain: Bool = false, session: String = "session") -> CachedFileV2 {
        CachedFileV2(mtimeUnix: 1, earliestTimestampUnix: earliest, project: "project", sessionId: session, isSidechain: sidechain, entries: entries, activityByDate: ["2026-10-25": .init(turns: 2, activeMinutes: 4, toolCounts: ["Bash": 1], linesWritten: 2, modelCounts: ["Fable": 1])])
    }

    @discardableResult
    private func save(_ db: UsageDatabase, _ name: String, _ file: CachedFileV2, mtime: Int64 = 1, size: Int64 = 1000) throws -> Bool {
        try db.synchronize(relativePath: name, parsed: file, signature: .init(mtime: mtime, size: size, identity: name), parserVersion: 1)
    }

    private func scalar(_ db: UsageDatabase, _ sql: String) throws -> Int { try db.read { try Int.fetchOne($0, sql: sql)! } }

    func testSchemaAndDurabilityConfiguration() throws {
        let db = try database()
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('session_files','usage_records')"), 2)
        XCTAssertEqual(try db.writerSynchronousMode(), 2)
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "wal")
    }

    func testGlobalMaxOutputDedupAndAnonymousRecords() throws {
        let db = try database()
        try save(db, "a.jsonl", file([entry(output: 10), entry(nil)]))
        try save(db, "b.jsonl", file([entry(output: 20), entry(nil)], earliest: 20, session: "other"))
        let winners = try db.winners()
        XCTAssertEqual(winners.count, 3)
        XCTAssertEqual(winners.first { $0.entry.hash != nil }?.entry.output, 20)
        XCTAssertEqual(winners.first { $0.entry.hash != nil }?.sessionKey, "other")
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM usage_records"), 4)
    }

    func testEqualOutputKeepsEarliestFileThenPath() throws {
        let db = try database()
        try save(db, "z.jsonl", file([entry()], earliest: 9, session: "earliest"))
        try save(db, "a.jsonl", file([entry()], earliest: 10, session: "later"))
        XCTAssertEqual(try db.winners().first?.sessionKey, "earliest")
        try save(db, "b.jsonl", file([entry("different")], earliest: 10, session: "b"))
        try save(db, "a2.jsonl", file([entry("different")], earliest: 10, session: "a2"))
        XCTAssertEqual(try db.winners().first { $0.entry.hash == "different" }?.sessionKey, "a2")
    }

    func testUpdateOnlyChangedUsageRecord() throws {
        let db = try database()
        try save(db, "a.jsonl", file([entry("one"), entry("two")]))
        let before: [Int64] = try db.read { try Int64.fetchAll($0, sql: "SELECT updated_at_us FROM usage_records ORDER BY id") }
        let changes = db.totalChanges()
        try save(db, "a.jsonl", file([entry("one"), entry("two", output: 30), entry("three")]), mtime: 2, size: 2000)
        let after: [Int64] = try db.read { try Int64.fetchAll($0, sql: "SELECT updated_at_us FROM usage_records ORDER BY id") }
        XCTAssertEqual(before[0], after[0])
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(db.totalChanges() - changes, 3) // file + updated row + inserted row
    }

    func testMissingSourceKeepsHistoryAndActivity() throws {
        let db = try database()
        try save(db, "a.jsonl", file([entry()]))
        try db.setStatus(id: try db.files().values.first!.id, status: "missing")
        XCTAssertEqual(try db.winners().count, 1)
        XCTAssertEqual(try db.activity(on: "2026-10-25").conversationTurns, 2)
    }

    func testTruncationAndAnonymousRewriteAreRejected() throws {
        let db = try database()
        try save(db, "a.jsonl", file([entry(), entry(nil)]))
        XCTAssertFalse(try save(db, "a.jsonl", file([]), mtime: 2, size: 10))
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM usage_records"), 2)
        XCTAssertEqual(try db.files().values.first?.mtime, 1)
        XCTAssertEqual(try db.files().values.first?.status, "needs_review")
        XCTAssertFalse(try save(db, "a.jsonl", file([entry(), entry(nil, input: 999)]), mtime: 3, size: 3000))
        XCTAssertEqual(try db.winners().first { $0.entry.hash == nil }?.entry.input, 3)
    }

    func testSidechainCostsIncludedButActivityExcluded() throws {
        let db = try database()
        try save(db, "a.jsonl", file([entry("main")]))
        try save(db, "subagents/b.jsonl", file([entry("sub")], sidechain: true))
        XCTAssertEqual(try db.winners().count, 2)
        XCTAssertEqual(try db.activity(on: "2026-10-25").conversationTurns, 2)
    }

    private func legacyData() throws -> Data {
        var row = entry()
        row.timestampUnix = nil
        let value = file([row], earliest: .greatestFiniteMagnitude)
        var rawFile = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        rawFile["future_file_field"] = ["keep": true]
        var entries = rawFile["entries"] as! [[String: Any]]
        entries[0]["future_entry_field"] = ["keep": "yes"]
        rawFile["entries"] = entries
        var days = rawFile["activityByDate"] as! [String: [String: Any]]
        days["2026-10-25"]?["future_activity"] = 42
        rawFile["activityByDate"] = days
        return try JSONSerialization.data(withJSONObject: ["version": 3, "files": [root.appendingPathComponent("a.jsonl").path: rawFile]])
    }

    func testLegacyImportPreservesUnknownFieldsAndMissingTimes() throws {
        let legacy = directory.appendingPathComponent("old.json")
        try legacyData().write(to: legacy)
        let db = try database(legacy: legacy)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM usage_records"), 1)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM usage_records WHERE timestamp_us IS NULL"), 1)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files WHERE earliest_timestamp_us IS NULL AND statistics_timezone IS NULL"), 1)
        XCTAssertEqual(try scalar(db, "SELECT json_extract(extensions_json,'$.future_entry_field.keep')='yes' FROM usage_records"), 1)
        XCTAssertEqual(try scalar(db, "SELECT json_extract(extensions_json,'$.legacy_fields.future_file_field.keep') FROM session_files"), 1)
        XCTAssertEqual(try scalar(db, "SELECT json_extract(activity_by_date_json,'$.days.\"2026-10-25\".future_activity') FROM session_files"), 42)
        XCTAssertEqual(try db.activity(on: "2026-10-25").conversationTurns, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLegacyImportSurvivesDuplicateHashesAndAliasedPaths() throws {
        func raw(_ file: CachedFileV2) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) }
        // Same hash three times with the largest output in the middle: the largest must stay.
        let first = try raw(file([entry(output: 5), entry(output: 50), entry(output: 20), entry("other:request", output: 7)]))
        let unrelated = try raw(file([entry("unrelated:request", output: 9)], session: "other"))
        // Sorts after b.jsonl and canonicalizes to a.jsonl, so it is skipped between real files.
        let aliasContent = try raw(file([entry("alias:only", output: 99)]))
        let legacy = directory.appendingPathComponent("old.json")
        try JSONSerialization.data(withJSONObject: ["version": 3, "files": [
            root.appendingPathComponent("a.jsonl").path: first,
            root.appendingPathComponent("b.jsonl").path: unrelated,
            root.appendingPathComponent("sub/../a.jsonl").path: aliasContent,
        ]]).write(to: legacy)

        let db = try database(legacy: legacy)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files"), 2)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM usage_records"), 3)
        XCTAssertEqual(try scalar(db, "SELECT output_tokens FROM usage_records WHERE record_key='id:message:request'"), 50)
        // The first path wins; the aliased copy's records must not land in any file.
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM usage_records WHERE record_key='id:alias:only'"), 0)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM usage_records u JOIN session_files f ON f.id=u.file_id WHERE f.relative_path='b.jsonl'"), 1)
    }

    func testUnreadableLegacyIsTreatedAsMissing() throws {
        let legacy = directory.appendingPathComponent("old.json")
        // A directory at the legacy path makes the read itself fail.
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let db = try database(legacy: legacy)
        XCTAssertTrue(try db.winners().isEmpty)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='v2_import_legacy_json_v3'"), 1)
    }

    func testCompletedImportNeverResurrectsRows() throws {
        let legacy = directory.appendingPathComponent("old.json")
        try legacyData().write(to: legacy)
        do {
            let db = try database(legacy: legacy)
            XCTAssertEqual(try db.winners().count, 1)
            try db.testingWrite { db in
                try db.execute(sql: "DELETE FROM usage_records; DELETE FROM session_files")
            }
        }
        let reopened = try database(legacy: legacy)
        XCTAssertTrue(try reopened.winners().isEmpty)
        XCTAssertEqual(try scalar(reopened, "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='v2_import_legacy_json_v3'"), 1)
    }

    func testUndecodableOrOtherVersionLegacyIsSkippedLikeTheOldApp() throws {
        for (index, content) in [Data("invalid".utf8), try JSONSerialization.data(withJSONObject: ["version": 2, "files": [:]])].enumerated() {
            let legacy = directory.appendingPathComponent("old\(index).json")
            try content.write(to: legacy)
            let db = try UsageDatabase(url: directory.appendingPathComponent("skip\(index).sqlite"), root: root, legacyURL: legacy, timezone: utc)
            XCTAssertTrue(try db.winners().isEmpty)
            XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='v2_import_legacy_json_v3'"), 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    func testLegacySourcesOutsideRootAreSkippedIndividually() throws {
        let inside = try JSONSerialization.jsonObject(with: legacyData()) as! [String: Any]
        var files = inside["files"] as! [String: Any]
        files[directory.appendingPathComponent("elsewhere/b.jsonl").path] = files.values.first!
        let legacy = directory.appendingPathComponent("old.json")
        try JSONSerialization.data(withJSONObject: ["version": 3, "files": files]).write(to: legacy)
        let db = try database(legacy: legacy)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files"), 1)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files WHERE relative_path='a.jsonl'"), 1)
    }

    func testEmptyInitialImportHasReceipt() throws {
        let legacy = directory.appendingPathComponent("old.json")
        _ = try database(legacy: legacy)
        try legacyData().write(to: legacy)
        XCTAssertTrue(try database(legacy: legacy).winners().isEmpty)
    }

    func testFutureSchemaRefusedWithoutErasure() throws {
        let db = try database()
        try save(db, "a.jsonl", file([entry()]))
        try db.testingWrite { try $0.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('future_version')") }
        XCTAssertThrowsError(try database())
        XCTAssertEqual(try db.winners().count, 1)
    }

    func testFailedTransactionDoesNotAdvanceFileSignature() throws {
        let db = try database()
        try save(db, "a.jsonl", file([entry()]))
        XCTAssertThrowsError(try save(db, "a.jsonl", file([entry(), entry("new", input: -1)]), mtime: 2, size: 2000))
        XCTAssertEqual(try db.files().values.first?.mtime, 1)
        XCTAssertEqual(try db.winners().count, 1)
    }

    private func transcript(_ output: Int, id: String = "message", timestamp: String = "2026-10-25T00:00:00.000Z") throws -> Data {
        let row: [String: Any] = ["timestamp": timestamp,"version":"2.0.0","sessionId":"session","requestId":"request-" + id,"type":"assistant","message":["id":id,"model":"claude-fable-5-1","usage":["input_tokens":3,"output_tokens":output],"content":[]]]
        return try JSONSerialization.data(withJSONObject: row) + Data("\n".utf8)
    }

    private func unicodeTranscript(newline: String) throws -> Data {
        var text = String(decoding: try transcript(2), as: UTF8.self).trimmingCharacters(in: .newlines)
        var final = try XCTUnwrap(JSONSerialization.jsonObject(with: transcript(9)) as? [String: Any])
        var message = try XCTUnwrap(final["message"] as? [String: Any])
        message["content"] = [["type": "text", "text": "alpha\u{2028}beta\u{2029}gamma\u{0085}delta"]]
        final["message"] = message
        var encoded = String(decoding: try JSONSerialization.data(withJSONObject: final), as: UTF8.self)
        for scalar in ["2028", "2029", "0085"] {
            encoded = encoded.replacingOccurrences(of: "\\u" + scalar, with: String(UnicodeScalar(UInt32(scalar, radix: 16)!)!))
        }
        XCTAssertTrue(encoded.contains("\u{2028}"))
        XCTAssertTrue(encoded.contains("\u{2029}"))
        XCTAssertTrue(encoded.contains("\u{0085}"))
        text += newline + encoded + newline
        return Data(text.utf8)
    }

    func testJSONLUsesLFBytesAndPreservesUnicodeSeparatorsInStrings() throws {
        let path = root.appendingPathComponent("unicode.jsonl")
        for newline in ["\n", "\r\n"] {
            try unicodeTranscript(newline: newline).write(to: path)
            let parsed = try XCTUnwrap(parseSessionFile(at: path.path, relativePath: "unicode.jsonl", mtime: 1, timezone: utc))
            XCTAssertEqual(parsed.entries.count, 1)
            XCTAssertEqual(parsed.entries.first?.output, 9)
            XCTAssertEqual(parsed.activityByDate["2026-10-25"]?.modelCounts.values.reduce(0, +), 1)
        }
    }

    func testParserUpgradeRepairsStoredPartialUsageWithoutSourceChanges() async throws {
        XCTAssertGreaterThan(SessionUsageStore.parserVersion, 1)
        let path = root.appendingPathComponent("unicode.jsonl")
        try unicodeTranscript(newline: "\r\n").write(to: path)
        let signature = try SessionFileSignature.read(path.path)
        let parsed = try XCTUnwrap(parseSessionFile(at: path.path, relativePath: "unicode.jsonl", mtime: Double(signature.mtime) / 1_000_000_000, timezone: utc))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed)) as? [String: Any])
        var entries = try XCTUnwrap(raw["entries"] as? [[String: Any]])
        entries[0]["output"] = 2
        raw["entries"] = entries
        let partial = try JSONDecoder().decode(CachedFileV2.self, from: JSONSerialization.data(withJSONObject: raw))
        let db = try database()
        XCTAssertTrue(try db.synchronize(relativePath: "unicode.jsonl", parsed: partial, signature: signature, parserVersion: 1))
        let oldID = try db.files().values.first?.id
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        let warning = try await store.refreshLocalFiles()
        XCTAssertNil(warning)
        XCTAssertEqual(try db.winners().first?.entry.output, 9)
        XCTAssertEqual(try db.files().values.first?.id, oldID)
        XCTAssertEqual(try db.files().values.first?.parserVersion, SessionUsageStore.parserVersion)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM usage_records"), 1)
    }

    func testParserUpgradeRealignsAnonymousRowsAndPreservesExtensions() async throws {
        try await verifyAnonymousUpgrade(outputs: [2, 9, 4], accepted: true)
    }

    func testParserUpgradeRejectsAmbiguousAnonymousAlignment() async throws {
        try await verifyAnonymousUpgrade(outputs: [2, 2, 2], accepted: false)
    }

    func testLegacyJSONUpgradeRealignsRecoveredAnonymousRows() async throws {
        try await verifyAnonymousUpgrade(outputs: [2, 9, 4], accepted: true, legacy: true)
    }

    func testLegacyJSONUpgradeRetainsAmbiguousAnonymousRows() async throws {
        try await verifyAnonymousUpgrade(outputs: [2, 2, 2], accepted: false, legacy: true)
    }

    private func verifyAnonymousUpgrade(outputs: [Int], accepted: Bool, legacy: Bool = false) async throws {
        let path = root.appendingPathComponent("anonymous.jsonl")
        var data = Data()
        for output in outputs {
            var row = try XCTUnwrap(JSONSerialization.jsonObject(with: transcript(output)) as? [String: Any])
            row.removeValue(forKey: "requestId")
            data += try JSONSerialization.data(withJSONObject: row) + Data([0x0A])
        }
        try data.write(to: path)
        let signature = try SessionFileSignature.read(path.path)
        let parsed = try XCTUnwrap(parseSessionFile(at: path.path, relativePath: "anonymous.jsonl", mtime: 1, timezone: utc))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed)) as? [String: Any])
        var oldEntries = try XCTUnwrap(raw["entries"] as? [[String: Any]])
        oldEntries.remove(at: 1) // V1 skipped the middle row; V2 now recovers it.
        if legacy { oldEntries = oldEntries.map { $0.filter { $0.key != "timestampUnix" } } }
        raw["entries"] = oldEntries
        let partial = try JSONDecoder().decode(CachedFileV2.self, from: JSONSerialization.data(withJSONObject: raw))
        let db: UsageDatabase
        if legacy {
            let legacyURL = directory.appendingPathComponent("legacy.json")
            try JSONSerialization.data(withJSONObject: ["version":3,"files":[path.path:raw]]).write(to: legacyURL)
            db = try database(legacy: legacyURL)
        } else {
            db = try database()
            XCTAssertTrue(try db.synchronize(relativePath: "anonymous.jsonl", parsed: partial, signature: signature, parserVersion: 1))
        }
        try db.testingWrite { try $0.execute(sql: "UPDATE usage_records SET extensions_json=json_set(extensions_json,'$.future_marker','preserved') WHERE record_key='anonymous:1'") }
        let oldID = try db.read { try Int64.fetchOne($0, sql: "SELECT id FROM usage_records WHERE record_key='anonymous:1'") }
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        let warning = try await store.refreshLocalFiles()
        XCTAssertEqual(warning == nil, accepted)
        XCTAssertEqual(try db.winners().count, accepted ? 3 : 2)
        XCTAssertEqual(try db.files().values.first?.parserVersion, accepted ? 2 : (legacy ? 0 : 1))
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT record_key FROM usage_records WHERE id=? AND json_extract(extensions_json,'$.future_marker')='preserved'", arguments: [oldID]) }, accepted ? "anonymous:2" : "anonymous:1")
    }

    func testScanningUnchangedFilesMakesNoBusinessWritesAndRenameDoesNotDuplicate() async throws {
        let path = root.appendingPathComponent("project/a.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try transcript(10).write(to: path)
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        let warning1 = try await store.refreshLocalFiles()
        XCTAssertNil(warning1)
        let observer = try database()
        let rowsBefore = try observer.read { try Row.fetchAll($0, sql: "SELECT updated_at_us FROM session_files UNION ALL SELECT updated_at_us FROM usage_records").map { $0[0] as Int64 } }
        let warning2 = try await store.refreshLocalFiles()
        XCTAssertNil(warning2)
        XCTAssertEqual(try observer.read { try Row.fetchAll($0, sql: "SELECT updated_at_us FROM session_files UNION ALL SELECT updated_at_us FROM usage_records").map { $0[0] as Int64 } }, rowsBefore)
        let moved = path.deletingLastPathComponent().appendingPathComponent("renamed.jsonl")
        try FileManager.default.moveItem(at: path, to: moved)
        let warning3 = try await store.refreshLocalFiles()
        XCTAssertNil(warning3)
        XCTAssertEqual(try scalar(observer, "SELECT COUNT(*) FROM session_files"), 1)
        XCTAssertEqual(try observer.winners().count, 1)
        try FileManager.default.removeItem(at: moved)
        let warning4 = try await store.refreshLocalFiles()
        XCTAssertNil(warning4)
        XCTAssertEqual(try observer.winners().count, 1)
        XCTAssertEqual(try observer.files().values.first?.status, "missing")
    }

    func testSameContentCopyIsNotCountedTwice() async throws {
        let first = root.appendingPathComponent("first.jsonl")
        try transcript(10).write(to: first)
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await store.refreshLocalFiles()
        try FileManager.default.copyItem(at: first, to: root.appendingPathComponent("copy.jsonl"))
        let warning5 = try await store.refreshLocalFiles()
        XCTAssertNotNil(warning5)
        XCTAssertEqual(try scalar(database(), "SELECT COUNT(*) FROM session_files"), 1)
    }

    func testResumeFileWithSharedIDsIncludesNewUsage() async throws {
        try transcript(2, id: "shared").write(to: root.appendingPathComponent("first.jsonl"))
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        let firstWarning = try await store.refreshLocalFiles()
        XCTAssertNil(firstWarning)
        try (transcript(9, id: "shared") + transcript(15, id: "followup")).write(to: root.appendingPathComponent("resume.jsonl"))
        let warning = try await store.refreshLocalFiles()
        XCTAssertNil(warning)
        let db = try database()
        XCTAssertEqual(try db.winners().count, 2)
        XCTAssertEqual(try db.winners().first { $0.entry.hash == "shared:request-shared" }?.entry.output, 9)
        XCTAssertTrue(try db.files().values.allSatisfy { $0.status == "present" })
    }

    func testInvalidSourceConstraintDoesNotPreventOtherFilesAndRetriesChanges() async throws {
        let bad = root.appendingPathComponent("a-invalid.jsonl")
        try transcript(-1, id: "invalid").write(to: bad)
        try transcript(12, id: "valid").write(to: root.appendingPathComponent("z-valid.jsonl"))
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        let warning = try await store.refreshLocalFiles()
        XCTAssertNotNil(warning)
        XCTAssertEqual(try database().winners().first?.entry.output, 12)
        let repeatedWarning = try await store.refreshLocalFiles()
        XCTAssertNotNil(repeatedWarning)
        try transcript(13, id: "repaired").write(to: bad)
        let repairedWarning = try await store.refreshLocalFiles()
        XCTAssertNil(repairedWarning)
        XCTAssertEqual(try database().winners().count, 2)
    }

    func testNeedsReviewSourceIsVerifiedAgainEvenWithMatchingAcceptedSignature() async throws {
        let path = root.appendingPathComponent("a.jsonl")
        try transcript(12).write(to: path)
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await store.refreshLocalFiles()
        let db = try database()
        let state = try XCTUnwrap(db.files().values.first)
        try db.setStatus(id: state.id, status: "needs_review")
        let warning = try await store.refreshLocalFiles()
        XCTAssertNil(warning)
        XCTAssertEqual(try db.files().values.first?.status, "present")
        XCTAssertEqual(try db.winners().count, 1)
    }

    func testRelocationPreservesNeedsReviewStatus() throws {
        let db = try database()
        try save(db, "old.jsonl", file([entry()]))
        let state = try XCTUnwrap(db.files().values.first)
        try db.setStatus(id: state.id, status: "needs_review")
        try db.relocate(try XCTUnwrap(db.file(at: state.path)), relativePath: "renamed.jsonl")
        XCTAssertEqual(try db.files().values.first?.status, "needs_review")
        XCTAssertEqual(try db.winners().count, 1)
    }

    func testReportingTimezoneSurvivesDifferentSystemPreference() throws {
        let singapore = TimeZone(identifier: "Asia/Singapore")!
        let db = try UsageDatabase(url: databaseURL, root: root, legacyURL: nil, timezone: singapore)
        try save(db, "a.jsonl", file([entry()]))
        XCTAssertEqual(try database().reportingTimezone.identifier, singapore.identifier)
        let instant = ISO8601DateFormatter().date(from: "2026-10-24T18:00:00Z")!
        XCTAssertEqual(SessionUsageStore.dateString(instant, timezone: singapore), "2026-10-25")
        XCTAssertEqual(SessionUsageStore.dateString(instant, timezone: utc), "2026-10-24")
    }
    func testWinnerQueryDoesNotBuildTemporarySortTrees() throws {
        let db = try database()
        let details = try db.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + UsageDatabase.winnerSQL).map { $0["detail"] as String }
        }
        XCTAssertFalse(details.contains { $0.contains("TEMP B-TREE") }, details.joined(separator: "\n"))
        XCTAssertTrue(details.contains { $0.contains("usage_records_dedup") })
    }

    func testSQLiteStatisticsPreservePricingAndGlobalDateDedupRules() throws {
        let db = try database()
        func row(_ hash: String?, date: String, input: Int, output: Int, cw: Int = 0, cw1h: Int = 0, cr: Int = 0, speed: String? = nil) -> CachedEntryV2 {
            .init(hash: hash, date: date, hour: 0, model: "claude-fable-5-1", speed: speed, input: input, output: output, cw: cw, cw1h: cw1h, cr: cr, costUSDRow: nil, tools: [:], linesWritten: 0)
        }
        try save(db, "a.jsonl", file([
            row("stream", date: "2026-10-24", input: 250_000, output: 5, cw: 1000, cw1h: 200, cr: 500, speed: "fast"),
            row(nil, date: "2026-10-25", input: 1, output: 1)
        ], session: "a"))
        try save(db, "b.jsonl", file([
            row("stream", date: "2026-10-25", input: 250_000, output: 10, cw: 1000, cw1h: 200, cr: 500, speed: "fast")
        ], session: "b"))
        try save(db, "c.jsonl", file([row("yesterday", date: "2026-10-24", input: 100, output: 10)], session: "c"))
        let price = LiteLLMModelPricing(inputPerToken: 0.001, outputPerToken: 0.002, cacheCreatePerToken: 0.003, cacheCreate1hPerToken: 0.005, cacheReadPerToken: 0.004, inputAbove200k: 0.002, outputAbove200k: 0.004, cacheCreateAbove200k: 0.006, cacheReadAbove200k: 0.008, fastMultiplier: 2)
        let summary = SessionUsageStore.summarize(try db.winners(), prices: ["claude-fable-5-1": price], today: "2026-10-25")
        // (200k*.001 + 50k*.002 + 10*.002 + 800*.003 + 200*.005 + 500*.004)*2 + .003
        XCTAssertEqual(summary.todayCost, 610.843, accuracy: 0.000_001)
        XCTAssertEqual(summary.dailyCosts.count, 2)
        let today = try XCTUnwrap(summary.dailyCosts.first { $0.date == "2026-10-25" })
        XCTAssertEqual(today.inputTokens, 250_001)
        XCTAssertEqual(today.outputTokens, 11)
        XCTAssertEqual(today.cacheWriteTokens, 1000)
        XCTAssertEqual(today.cacheReadTokens, 500)
        XCTAssertEqual(today.sessionCount, 2)
        XCTAssertEqual(summary.dailyCosts.first { $0.date == "2026-10-24" }?.totalCost ?? -1, 0.12, accuracy: 0.000_001)
    }

    func testRestartWithoutSourceDirectoryStillReadsSavedHistory() async throws {
        try transcript(10).write(to: root.appendingPathComponent("a.jsonl"))
        let original = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await original.refreshLocalFiles()
        try FileManager.default.removeItem(at: root)
        let restarted = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        let warning = try await restarted.refreshLocalFiles()
        XCTAssertNotNil(warning)
        let timezone = try await restarted.reportingTimezoneIdentifier()
        XCTAssertEqual(timezone, utc.identifier)
        XCTAssertEqual(try database().winners().count, 1)
    }

    func testMoveIntoSubagentFolderUpdatesActivityClassification() async throws {
        let first = root.appendingPathComponent("project/a.jsonl")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try transcript(10).write(to: first)
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await store.refreshLocalFiles()
        let moved = root.appendingPathComponent("other/session/subagents/a.jsonl")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: first, to: moved)
        let warning = try await store.refreshLocalFiles()
        XCTAssertNil(warning)
        let db = try database()
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files WHERE project_key='other' AND is_sidechain=1"), 1)
        XCTAssertEqual(try db.activity(on: "2026-10-25").activeCodingMinutes, 0)
        XCTAssertEqual(try db.winners().count, 1)
    }

    func testGrowingInPlaceRewriteIsRejectedButNormalAppendWorks() async throws {
        let path = root.appendingPathComponent("a.jsonl")
        try transcript(10).write(to: path)
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await store.refreshLocalFiles()
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: transcript(20))
        try handle.close()
        let appendWarning = try await store.refreshLocalFiles()
        XCTAssertNil(appendWarning)
        XCTAssertEqual(try database().winners().first?.entry.output, 20)
        let identity = try SessionFileSignature.read(path.path).identity
        let rewrite = try FileHandle(forWritingTo: path)
        try rewrite.truncate(atOffset: 0)
        try rewrite.write(contentsOf: transcript(999) + transcript(999, id: "extra"))
        try rewrite.close()
        XCTAssertEqual(identity, try SessionFileSignature.read(path.path).identity)
        let rewriteWarning = try await store.refreshLocalFiles()
        XCTAssertNotNil(rewriteWarning)
        XCTAssertEqual(try database().winners().count, 1)
        XCTAssertEqual(try database().winners().first?.entry.output, 20)
    }

    func testLegacyMoveDoesNotDuplicateAnonymousUsageOrActivity() async throws {
        let original = root.appendingPathComponent("project/a.jsonl")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        var anonymous = try JSONSerialization.jsonObject(with: transcript(10)) as! [String: Any]
        anonymous.removeValue(forKey: "requestId")
        try (transcript(10) + JSONSerialization.data(withJSONObject: anonymous) + Data("\n".utf8)).write(to: original)
        let parsed = try XCTUnwrap(parseSessionFile(at: original.path, relativePath: "project/a.jsonl", mtime: 1, timezone: utc))
        let encoder = JSONEncoder()
        let rawFile = try JSONSerialization.jsonObject(with: encoder.encode(parsed))
        let legacy = directory.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: ["version":3,"files":[original.path:rawFile]]).write(to: legacy)
        let moved = original.deletingLastPathComponent().appendingPathComponent("moved.jsonl")
        try FileManager.default.moveItem(at: original, to: moved)
        let append = try FileHandle(forWritingTo: moved)
        try append.seekToEnd()
        try append.write(contentsOf: transcript(20, id: "new-after-legacy-snapshot"))
        try append.close()
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, legacyURL: legacy, timezone: utc)
        let warning = try await store.refreshLocalFiles()
        XCTAssertNotNil(warning)
        let db = try database()
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files"), 1)
        XCTAssertEqual(try db.winners().count, 2)
    }

    func testArchivedCopyWithNewIdentityAndAppendCannotDuplicateAnonymousHistory() async throws {
        let original = root.appendingPathComponent("original.jsonl")
        var anonymous = try XCTUnwrap(JSONSerialization.jsonObject(with: transcript(10)) as? [String: Any])
        anonymous.removeValue(forKey: "requestId")
        try (JSONSerialization.data(withJSONObject: anonymous) + Data([0x0A])).write(to: original)
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await store.refreshLocalFiles()
        let oldIdentity = try SessionFileSignature.read(original.path).identity
        let copied = root.appendingPathComponent("copied.jsonl")
        try FileManager.default.copyItem(at: original, to: copied)
        try FileManager.default.removeItem(at: original)
        let handle = try FileHandle(forWritingTo: copied)
        try handle.seekToEnd()
        try handle.write(contentsOf: transcript(20, id: "new-after-copy"))
        try handle.close()
        XCTAssertNotEqual(oldIdentity, try SessionFileSignature.read(copied.path).identity)
        let warning = try await store.refreshLocalFiles()
        XCTAssertNotNil(warning)
        let db = try database()
        XCTAssertEqual(try db.winners().count, 1)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files"), 1)
    }

    func testUnknownLegacyTimezoneCannotSilentlyMoveDateBuckets() throws {
        let legacy = directory.appendingPathComponent("legacy.json")
        var raw = try JSONSerialization.jsonObject(with: legacyData()) as! [String: Any]
        var files = raw["files"] as! [String: [String: Any]]
        let path = root.appendingPathComponent("a.jsonl").path
        var entries = files[path]!["entries"] as! [[String: Any]]
        entries[0]["date"] = "2026-10-24"
        files[path]!["entries"] = entries
        raw["files"] = files
        try JSONSerialization.data(withJSONObject: raw).write(to: legacy)
        let db = try database(legacy: legacy)
        XCTAssertFalse(try save(db, "a.jsonl", file([entry()])))
        XCTAssertEqual(try db.winners().first?.entry.date, "2026-10-24")
    }

    func testUpdatingOneFileInHundredMegabyteHistoryWritesOnlySmallWAL() throws {
        let db = try database()
        try db.testingWrite { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000)
                INSERT INTO session_files(provider,root_path,relative_path,project_key,is_sidechain,
                    source_mtime_ns,source_size_bytes,earliest_timestamp_us,parser_version,statistics_timezone,
                    source_status,activity_by_date_json,extensions_json,created_at_us,updated_at_us)
                SELECT 'claude',?, 'bulk/'||x||'.jsonl','bulk',0,1,1000,10,1,'GMT','present',
                    '{"_v":1,"days":{}}','{"_v":1}',1,1 FROM n;
                INSERT INTO usage_records(file_id,record_key,dedup_key,source_order,local_date,model,speed,
                    input_tokens,output_tokens,cache_creation_tokens,cache_creation_1h_tokens,cache_read_tokens,
                    extensions_json,created_at_us,updated_at_us)
                SELECT id,'id:bulk-'||id,'bulk-'||id,0,'2026-10-25','claude-fable-5-1','standard',
                    3,10,100,20,200,json_object('padding',hex(zeroblob(6000))),1,1 FROM session_files;
                """, arguments: [root.path])
        }
        try db.testingCheckpoint()
        let size = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as! NSNumber
        XCTAssertGreaterThan(size.intValue, 100_000_000)
        let before = db.totalChanges()
        XCTAssertTrue(try save(db, "bulk/1.jsonl", file([entry("bulk-1", output: 20)]), mtime: 2, size: 2000))
        XCTAssertEqual(db.totalChanges() - before, 2)
        let wal = try FileManager.default.attributesOfItem(atPath: databaseURL.path + "-wal")[.size] as! NSNumber
        XCTAssertLessThan(wal.intValue, 512_000)
        print("SQLite write benchmark: database=\(size) bytes, one-file WAL=\(wal) bytes")
    }

    func testMultipleIdenticalArchivedSourcesStillBlockAnotherCopy() throws {
        let db = try database()
        var first = file([entry("one")])
        first.contentHash = "identical-fingerprint"
        var second = file([entry("two")])
        second.contentHash = "identical-fingerprint"
        try save(db, "a.jsonl", first)
        try save(db, "b.jsonl", second)
        XCTAssertNotNil(try db.identicalSource(first))
    }

    func testExistingJSONSnapshotImportMatchesOriginalAggregation() throws {
        let input = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CCSwitcher/session-parse-cache-v2.json")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("No local legacy snapshot; synthetic import tests cover CI") }
        let snapshot = try Data(contentsOf: input) // Read only; all database writes stay in this test's temporary directory.
        let legacy = directory.appendingPathComponent("local-snapshot.json")
        try snapshot.write(to: legacy)
        struct Envelope: Decodable { let version: Int; let files: [String: CachedFileV2] }
        let decoded = try JSONDecoder().decode(Envelope.self, from: snapshot)
        guard decoded.version == 3 else { throw XCTSkip("Local snapshot uses another historical format") }
        let sourceRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        // The import skips sources outside the current root; compare against the rest.
        let canonicalRoot = canonicalUsageSourceURL(sourceRoot).path + "/"
        let original = Envelope(version: decoded.version, files: decoded.files.filter {
            canonicalUsageSourceURL(URL(fileURLWithPath: $0.key)).path.hasPrefix(canonicalRoot)
        })
        let db = try UsageDatabase(url: databaseURL, root: sourceRoot, legacyURL: legacy, timezone: utc)
        // Reference is the former in-memory algorithm, applied to exactly the
        // same immutable JSON snapshot, not to today's changing source files.
        var best: [String: UsageDatabase.Winner] = [:]
        var anonymous: [UsageDatabase.Winner] = []
        let sorted = original.files.sorted {
            if $0.value.earliestTimestampUnix != $1.value.earliestTimestampUnix { return $0.value.earliestTimestampUnix < $1.value.earliestTimestampUnix }
            return $0.key < $1.key
        }
        for (path, file) in sorted {
            for entry in file.entries {
                let winner = UsageDatabase.Winner(entry: entry, sessionKey: file.sessionId ?? canonicalUsageSourceURL(URL(fileURLWithPath: path)).path)
                if let hash = entry.hash {
                    if best[hash] == nil || entry.output > best[hash]!.entry.output { best[hash] = winner }
                } else { anonymous.append(winner) }
            }
        }
        let expected = (Array(best.values) + anonymous).filter { $0.entry.model != "<synthetic>" }
        let actual = try db.winners()
        XCTAssertEqual(actual.count, expected.count)
        let samplePrice = LiteLLMModelPricing(inputPerToken: 0.000001, outputPerToken: 0.000002, cacheCreatePerToken: 0.00000125, cacheCreate1hPerToken: 0.000002, cacheReadPerToken: 0.0000001, inputAbove200k: 0.000002, outputAbove200k: 0.000004, cacheCreateAbove200k: 0.0000025, cacheReadAbove200k: 0.0000002, fastMultiplier: 2)
        let prices = Dictionary(uniqueKeysWithValues: Set(expected.map { $0.entry.model }).map { ($0, Optional(samplePrice)) })
        let reference = SessionUsageStore.summarize(expected, prices: prices, today: "2026-10-25")
        let migrated = SessionUsageStore.summarize(actual, prices: prices, today: "2026-10-25")
        XCTAssertEqual(reference.dailyCosts.count, migrated.dailyCosts.count)
        for day in reference.dailyCosts {
            let imported = try XCTUnwrap(migrated.dailyCosts.first { $0.date == day.date })
            XCTAssertEqual(imported.inputTokens, day.inputTokens)
            XCTAssertEqual(imported.outputTokens, day.outputTokens)
            XCTAssertEqual(imported.cacheWriteTokens, day.cacheWriteTokens)
            XCTAssertEqual(imported.cacheReadTokens, day.cacheReadTokens)
            XCTAssertEqual(imported.sessionCount, day.sessionCount)
            XCTAssertEqual(imported.totalCost, day.totalCost, accuracy: 0.00000001)
            let activity = try db.activity(on: day.date)
            let contributions = original.files.values.filter { !$0.isSidechain }.compactMap { $0.activityByDate[day.date] }
            XCTAssertEqual(activity.conversationTurns, contributions.reduce(0) { $0 + $1.turns })
            XCTAssertEqual(activity.activeCodingMinutes, contributions.reduce(0) { $0 + $1.activeMinutes })
            XCTAssertEqual(activity.linesWritten, contributions.reduce(0) { $0 + $1.linesWritten })
        }
        print("Local legacy parity: \(original.files.count) source files, \(original.files.values.reduce(0) { $0 + $1.entries.count }) records, \(actual.count) winners")
    }

    func testMovingWholeSourceDirectoryPreservesSourceIdentity() async throws {
        try transcript(10).write(to: root.appendingPathComponent("a.jsonl"))
        let original = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await original.refreshLocalFiles()
        let moved = directory.appendingPathComponent("moved-projects")
        try FileManager.default.moveItem(at: root, to: moved)
        let restarted = SessionUsageStore(databaseURL: databaseURL, projectsRoot: moved, timezone: utc)
        let warning = try await restarted.refreshLocalFiles()
        XCTAssertNil(warning)
        let db = try UsageDatabase(url: databaseURL, root: moved, legacyURL: nil, timezone: utc)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files"), 1)
        XCTAssertEqual(try db.winners().count, 1)
        XCTAssertEqual(try db.files().values.first?.path, canonicalUsageSourceURL(moved.appendingPathComponent("a.jsonl")).path)
    }

    func testReplacementPreservingSizeAndMtimeCannotUseFastPath() async throws {
        let path = root.appendingPathComponent("a.jsonl")
        try transcript(10).write(to: path)
        // Whole seconds survive Date/Double round-trips when restoring mtime.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: path.path)
        let store = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await store.refreshLocalFiles()
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let old = try SessionFileSignature.read(path.path)
        let replacement = directory.appendingPathComponent("replacement.jsonl")
        try FileManager.default.copyItem(at: path, to: replacement)
        try FileManager.default.setAttributes([.modificationDate:attributes[.modificationDate]!], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: replacement, to: path)
        let new = try SessionFileSignature.read(path.path)
        XCTAssertEqual(old.mtime, new.mtime)
        XCTAssertEqual(old.size, new.size)
        XCTAssertNotEqual(old.identity, new.identity)
        let warning = try await store.refreshLocalFiles()
        XCTAssertNotNil(warning)
        let db = try database()
        XCTAssertEqual(try db.files().values.first?.status, "needs_review")
        XCTAssertEqual(try db.winners().count, 1)
    }

    func testOverlappingRootRedefinitionReusesExistingSourceRow() async throws {
        let path = root.appendingPathComponent("a.jsonl")
        try transcript(10).write(to: path)
        let original = SessionUsageStore(databaseURL: databaseURL, projectsRoot: root, timezone: utc)
        _ = try await original.refreshLocalFiles()
        let widerRoot = SessionUsageStore(databaseURL: databaseURL, projectsRoot: directory, timezone: utc)
        let firstWarning = try await widerRoot.refreshLocalFiles()
        XCTAssertNil(firstWarning)
        let append = try FileHandle(forWritingTo: path)
        try append.seekToEnd()
        try append.write(contentsOf: transcript(20))
        try append.close()
        let secondWarning = try await widerRoot.refreshLocalFiles()
        XCTAssertNil(secondWarning)
        let db = try database()
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM session_files"), 1)
        XCTAssertEqual(try db.winners().count, 1)
        XCTAssertEqual(try db.winners().first?.entry.output, 20)
    }

}
