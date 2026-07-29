import Foundation

// MARK: - Provider Type (extensible for Gemini, Codex, etc.)

enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case gemini = "Gemini"
    case codex = "Codex"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .claudeCode: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var configDirectory: String {
        switch self {
        case .claudeCode: return "~/.claude"
        case .gemini: return "~/.gemini"
        case .codex: return "~/.codex"
        }
    }
}

// MARK: - Account Model

struct Account: Identifiable, Codable, Hashable {
    let id: UUID
    var email: String
    var displayName: String
    var provider: AIProviderType
    var orgName: String?
    var subscriptionType: String?
    var isActive: Bool
    var lastUsed: Date?
    var customLabel: String?

    /// Subscription type with first letter capitalized (e.g., "max" → "Max").
    var displaySubscriptionType: String? {
        subscriptionType?.prefix(1).uppercased().appending(subscriptionType?.dropFirst() ?? "")
    }

    var obfuscatedEmail: String {
        return email.obfuscatedEmail()
    }

    var obfuscatedDisplayName: String {
        return displayName.obfuscatedEmail()
    }

    /// Returns customLabel if set and non-empty, otherwise falls back to obfuscatedDisplayName.
    var effectiveDisplayName: String {
        if let label = customLabel, !label.isEmpty {
            return label
        }
        return obfuscatedDisplayName
    }

    /// Returns the email, optionally obfuscated.
    func displayEmail(obfuscated: Bool) -> String {
        obfuscated ? obfuscatedEmail : email
    }

    /// Returns the effective display name, optionally obfuscating the fallback.
    func effectiveDisplayName(obfuscated: Bool) -> String {
        if let label = customLabel, !label.isEmpty {
            return label
        }
        return obfuscated ? obfuscatedDisplayName : displayName
    }

    init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        provider: AIProviderType = .claudeCode,
        orgName: String? = nil,
        subscriptionType: String? = nil,
        isActive: Bool = false,
        lastUsed: Date? = nil,
        customLabel: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.orgName = orgName
        self.subscriptionType = subscriptionType
        self.isActive = isActive
        self.lastUsed = lastUsed
        self.customLabel = customLabel
    }
}

// MARK: - Auth Status (from `claude auth status`)

/// Decoded `claude auth status` output.
///
/// The CLI only emits `email`, `orgId`, `orgName` and `subscriptionType` when
/// `authMethod == "claude.ai"` — that is, when the stored claude.ai login is the
/// credential source it actually resolves to. Any higher-precedence source
/// shadows the stored login and the whole identity block is omitted while
/// `loggedIn` stays `true`: an `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN`
/// environment variable, an `apiKeyHelper`, an OAuth token file, an Anthropic
/// profile in `~/.config/anthropic`, or a third-party provider (Bedrock, Vertex,
/// …). Callers must therefore treat a missing `email` as "identity unavailable",
/// never as "a different account is active".
struct AuthStatus: Codable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let email: String?
    let orgId: String?
    let orgName: String?
    let subscriptionType: String?

    /// True when the CLI reports the identity of the stored claude.ai login,
    /// i.e. when `email` is meaningful.
    var reportsClaudeAiIdentity: Bool {
        authMethod == "claude.ai"
    }

    /// The credential source shadowing the stored claude.ai login, or `nil` when
    /// nothing shadows it. Only meaningful while `loggedIn` is `true`.
    var shadowingAuthMethod: String? {
        reportsClaudeAiIdentity ? nil : (authMethod ?? "unknown")
    }
}
