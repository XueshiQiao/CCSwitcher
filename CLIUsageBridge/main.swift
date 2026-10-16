import Foundation
import Darwin

struct BridgeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Identity: Codable, Equatable {
    let accountUuid: String
    let email: String
    let organizationUuid: String?
}

struct Window: Codable, Equatable {
    let used_percentage: Double
    let resets_at: Double

    func validate() throws {
        guard used_percentage.isFinite, (0...100).contains(used_percentage),
              resets_at.isFinite, resets_at > 0,
              resets_at <= Date.distantFuture.timeIntervalSince1970 else {
            throw BridgeFailure(message: "Invalid CLI rate-limit window")
        }
    }
}

struct RateLimits: Codable, Equatable {
    let five_hour: Window?
    let seven_day: Window?

    func validate() throws {
        try five_hour?.validate()
        try seven_day?.validate()
    }
    var isEmpty: Bool { five_hour == nil && seven_day == nil }
}

struct Input: Decodable {
    let session_id: String
    let cwd: String?
    let rate_limits: RateLimits?
}

struct Session: Codable {
    let identity: Identity
    var invalidated: Bool
    var rateLimits: RateLimits?
    var observedAt: Double?
}

struct Snapshot: Codable {
    let version: Int
    let accountUuid: String
    let email: String
    let observedAt: Double
    let sessionId: String
    let rateLimits: RateLimits
}

struct Manifest: Decodable {
    let version: Int
    let originalCommand: String?
}

struct Bridge {
    let home: URL
    var root: URL { home.appendingPathComponent(".ccswitcher/cli-usage") }
    let manager = FileManager.default

    func json(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw BridgeFailure(message: "Expected a JSON object in \(url.lastPathComponent)")
        }
        return object
    }

    func identity(input: Input) throws -> Identity {
        let environment = ProcessInfo.processInfo.environment
        let overrides = ["ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY",
                         "ANTHROPIC_PROFILE", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
                         "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_CONFIG_DIR",
                         "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_IDENTITY_TOKEN",
                         "CLAUDE_CODE_OAUTH_TOKEN_FILE", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"]
        guard !overrides.contains(where: { !(environment[$0] ?? "").isEmpty }) else {
            throw BridgeFailure(message: "CLI authentication override: quota identity cannot be established")
        }
        if let directory = environment["CLAUDE_CONFIG_DIR"],
           URL(fileURLWithPath: directory).standardizedFileURL != home.appendingPathComponent(".claude").standardizedFileURL {
            throw BridgeFailure(message: "Custom Claude configuration directory is not supported")
        }
        let alternateCredentials = [".claude/.credentials.json", ".config/anthropic/active_config",
                                    ".config/anthropic/configs/default.json", ".config/anthropic/credentials/default.json"]
        guard !alternateCredentials.contains(where: { manager.fileExists(atPath: home.appendingPathComponent($0).path) }) else {
            throw BridgeFailure(message: "Alternate credential file or Anthropic profile: quota identity cannot be established")
        }
        var settings = [home.appendingPathComponent(".claude/settings.json"),
                        URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")]
        if let cwd = input.cwd {
            var directory = URL(fileURLWithPath: cwd).standardizedFileURL
            while true {
                settings += ["settings.json", "settings.local.json"].map {
                    directory.appendingPathComponent(".claude/" + $0)
                }
                let parent = directory.deletingLastPathComponent()
                if parent == directory { break }
                directory = parent
            }
        }
        for url in settings where manager.fileExists(atPath: url.path) {
            let object = try json(url)
            guard object["apiKeyHelper"] == nil, object["forceLoginGatewayUrl"] == nil,
                  (object["forceLoginMethod"] as? String).map({ $0 == "claudeai" }) ?? true else {
                throw BridgeFailure(message: "Configured API key helper: quota identity cannot be established")
            }
        }
        let config = try json(home.appendingPathComponent(".claude.json"))
        guard config["primaryApiKey"] == nil else {
            throw BridgeFailure(message: "Saved API key: quota identity cannot be established")
        }
        guard let oauth = config["oauthAccount"] as? [String: Any],
              let rawID = oauth["accountUuid"] as? String, let id = UUID(uuidString: rawID),
              let email = oauth["emailAddress"] as? String, !email.isEmpty else {
            throw BridgeFailure(message: "Local Claude OAuth identity is unavailable")
        }
        var organizationID: String?
        if let raw = oauth["organizationUuid"] {
            guard let string = raw as? String, let uuid = UUID(uuidString: string) else {
                throw BridgeFailure(message: "Invalid local OAuth organization identity")
            }
            organizationID = uuid.uuidString
        }
        return Identity(accountUuid: id.uuidString, email: email, organizationUuid: organizationID)
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func collect(_ data: Data, starting: Bool) throws {
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard let sessionID = UUID(uuidString: input.session_id)?.uuidString.lowercased() else {
            throw BridgeFailure(message: "Invalid CLI session identifier")
        }
        for directory in [root, root.appendingPathComponent("sessions"), root.appendingPathComponent("accounts")] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        let lock = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(lock, LOCK_UN) }

        let current = try identity(input: input)
        let sessionURL = root.appendingPathComponent("sessions/" + sessionID + ".json")
        var session: Session
        if manager.fileExists(atPath: sessionURL.path) {
            session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: sessionURL))
            if session.identity != current {
                session.invalidated = true
                try save(session, to: sessionURL)
            }
            guard !session.invalidated else {
                throw BridgeFailure(message: "CLI session account changed; start a new session to collect quota")
            }
        } else {
            guard starting else { throw BridgeFailure(message: "CLI session is unbound; start a new session to collect quota") }
            session = Session(identity: current, invalidated: false)
            try save(session, to: sessionURL)
        }
        guard !starting, let limits = input.rate_limits, !limits.isEmpty else { return }
        try limits.validate()
        guard limits != session.rateLimits else { return }
        let observedAt = Date().timeIntervalSince1970
        session.rateLimits = limits
        session.observedAt = observedAt
        // Commit the account first: if interrupted here, the next event can retry.
        let snapshot = Snapshot(version: 1, accountUuid: current.accountUuid, email: current.email,
                                observedAt: observedAt, sessionId: sessionID, rateLimits: limits)
        try save(snapshot, to: root.appendingPathComponent("accounts/" + current.accountUuid + ".json"))
        try save(session, to: sessionURL)
    }

    func forward(_ data: Data) throws -> Int32 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("installation.json")))
        guard manifest.version == 1 else { throw BridgeFailure(message: "Unsupported bridge installation manifest") }
        guard let command = manifest.originalCommand else { return 0 }
        let input = Pipe()
        let descriptor = input.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = input
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        // stdout/stderr are inherited, so no output pipe can block this input writer.
        // Original commands may intentionally ignore stdin: EPIPE is normal then.
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if errno == EINTR { continue }
                    if errno == EPIPE { break }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data(("CCSwitcher CLI cache: " + message + "\n").utf8))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 3, ["session-start", "statusline"].contains(arguments[0]), arguments[1] == "--home" else {
        throw BridgeFailure(message: "Usage: CCSwitcherCLI session-start|statusline --home HOME")
    }
    let home = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    let bridge = Bridge(home: home)
    let input = FileHandle.standardInput.readDataToEndOfFile()
    var failed = false
    do {
        guard input.count <= 2 * 1024 * 1024 else { throw BridgeFailure(message: "CLI status input exceeds 2 MiB") }
        try bridge.collect(input, starting: arguments[0] == "session-start")
    } catch {
        diagnostic(error.localizedDescription)
        failed = true
    }
    if arguments[0] == "statusline" {
        exit(try bridge.forward(input))
    }
    exit(failed ? 1 : 0)
} catch {
    diagnostic(error.localizedDescription)
    exit(1)
}
