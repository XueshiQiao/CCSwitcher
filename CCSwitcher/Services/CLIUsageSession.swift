import AppKit

/// An explicit, visible official-CLI check. This service never reads tokens or calls an API.
enum CLIUsageSession {
    private static let overrides = [
        "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_PROFILE",
        "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_MANTLE", "ANTHROPIC_CONFIG_DIR", "ANTHROPIC_FEDERATION_RULE_ID",
        "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_IDENTITY_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE",
        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_CLIENT_DATA_URL",
        "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
    ]
    private static let alternateCredentials = [".claude/.credentials.json", ".config/anthropic/active_config",
        ".config/anthropic/configs/default.json", ".config/anthropic/credentials/default.json"]

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func prepare(claudePath: String, home: URL, accountUuid: String, email: String) throws -> URL {
        let manager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let identityError = String(localized: "CLI account configuration is not supported for a quota check.", bundle: L10n.bundle)
        guard claudePath.hasPrefix("/"), manager.isExecutableFile(atPath: claudePath) else {
            throw Failure(message: String(localized: "Claude CLI executable is unavailable.", bundle: L10n.bundle))
        }
        guard UUID(uuidString: accountUuid) != nil, !email.isEmpty,
              !overrides.contains(where: { !(environment[$0] ?? "").isEmpty }),
              environment["CLAUDE_CONFIG_DIR"].map({ $0 == home.appendingPathComponent(".claude").path }) ?? true,
              !alternateCredentials.contains(where: { manager.fileExists(atPath: home.appendingPathComponent($0).path) }) else {
            throw Failure(message: identityError)
        }
        func object(_ url: URL) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw Failure(message: identityError)
            }
            return value
        }
        let configURL = home.appendingPathComponent(".claude.json")
        let config = try object(configURL)
        guard config["primaryApiKey"] == nil,
              let identity = config["oauthAccount"] as? [String: Any],
              identity["accountUuid"] as? String == accountUuid,
              identity["emailAddress"] as? String == email else { throw Failure(message: identityError) }
        let settings = [home.appendingPathComponent(".claude/settings.json"),
                        home.appendingPathComponent(".claude/settings.local.json"),
                        URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")]
        for url in settings where manager.fileExists(atPath: url.path) {
            let value = try object(url)
            guard value["apiKeyHelper"] == nil, value["forceLoginGatewayUrl"] == nil,
                  (value["forceLoginMethod"] as? String).map({ $0 == "claudeai" }) ?? true else {
                throw Failure(message: identityError)
            }
            if let configured = value["env"] as? [String: Any],
               overrides.contains(where: { configured[$0] != nil }) || configured["CLAUDE_CONFIG_DIR"] != nil {
                throw Failure(message: identityError)
            }
        }
        let directory = manager.temporaryDirectory.appendingPathComponent("CCSwitcher-usage-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("Check Claude Usage.command")
        // Recheck terminal environment and identity: opening Terminal is asynchronous.
        let environmentChecks = overrides.map { "[ -z \"${\($0):-}\" ] || refuse" }.joined(separator: "\n")
        let credentialChecks = alternateCredentials.map { "[ ! -e \(quote(home.appendingPathComponent($0).path)) ] || refuse" }.joined(separator: "\n")
        let content = """
        #!/bin/sh
        trap '/bin/rm -f -- "$0"; /bin/rmdir -- "${0%/*}"' EXIT
        refuse() { printf '%s\\n' 'Claude quota check stopped: account or authentication configuration changed.' >&2; exit 1; }
        [ "$HOME" = \(quote(home.path)) ] || refuse
        \(environmentChecks)
        [ -z "${CLAUDE_CONFIG_DIR:-}" ] || [ "$CLAUDE_CONFIG_DIR" = \(quote(home.appendingPathComponent(".claude").path)) ] || refuse
        \(credentialChecks)
        [ "$(/usr/bin/plutil -extract oauthAccount.accountUuid raw -o - \(quote(configURL.path)))" = \(quote(accountUuid)) ] || refuse
        [ "$(/usr/bin/plutil -extract oauthAccount.emailAddress raw -o - \(quote(configURL.path)))" = \(quote(email)) ] || refuse
        /usr/bin/plutil -extract primaryApiKey raw -o /dev/null \(quote(configURL.path)) 2>/dev/null && refuse
        cd \(quote(home.path)) || exit 1
        \(quote(claudePath)) --safe-mode '/usage'
        exit $?
        """
        do {
            try Data(content.utf8).write(to: script)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return script
        } catch {
            try manager.removeItem(at: directory)
            throw error
        }
    }

    static func open(claudePath: String, accountUuid: String, email: String) throws {
        let script = try prepare(claudePath: claudePath, home: FileManager.default.homeDirectoryForCurrentUser,
                                 accountUuid: accountUuid, email: email)
        guard NSWorkspace.shared.open(script) else {
            try FileManager.default.removeItem(at: script.deletingLastPathComponent())
            throw Failure(message: String(localized: "Could not open Terminal for the Claude quota check.", bundle: L10n.bundle))
        }
    }
}
