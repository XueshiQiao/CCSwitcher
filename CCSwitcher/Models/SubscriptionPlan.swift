import Foundation

/// Which plan to show for the logged-in account.
enum SubscriptionPlan {
    /// The CLI's own `organizationType` → plan table. Values outside it map to `nil`.
    private static let planByOrganizationType: [String: String] = [
        "claude_max": "max",
        "claude_pro": "pro",
        "claude_team": "team",
        "claude_enterprise": "enterprise",
    ]

    /// `subscriptionType` comes from the keychain credential, which the CLI
    /// stamps once and keeps through token refreshes, so it goes stale after a
    /// plan change. The `oauthAccount` profile in ~/.claude.json is refetched
    /// by the CLI at most once a day and follows the change, so its
    /// `organizationType` wins when the profile belongs to this login and the
    /// value is one the CLI knows. Anything else — a missing profile, another
    /// account's profile, a missing, non-string or unknown (future) value —
    /// keeps `subscriptionType`.
    static func resolve(email: String?, orgId: String?, subscriptionType: String?, profile: [String: Any]?) -> String? {
        guard let email,
              let profile,
              profile["emailAddress"] as? String == email else {
            return subscriptionType
        }
        // The same email can sit in several organizations; the profile must be
        // this login's organization. A profile without a usable org id can't
        // prove that, so it is not trusted either.
        if let orgId, profile["organizationUuid"] as? String != orgId {
            return subscriptionType
        }
        guard let organizationType = profile["organizationType"] as? String,
              let plan = planByOrganizationType[organizationType] else {
            return subscriptionType
        }
        return plan
    }
}
