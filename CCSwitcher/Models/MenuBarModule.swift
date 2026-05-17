import Foundation

/// One configurable module rendered in the macOS menu bar.
///
/// Display style matches iStats / Stats: two-line stacked module with a short
/// uppercase label on top and either a bar (for percentages) or a value text
/// (for absolute numbers / times) on the bottom.
enum MenuBarModule: String, Codable, CaseIterable, Identifiable {
    case account
    case sessionBar
    case sessionBarPlain
    case weeklyBar
    case weeklyBarPlain
    case dailyCost
    case sessionReset
    case weeklyReset

    var id: String { rawValue }

    /// Short uppercase label shown on the top line of the module.
    var compactLabel: String {
        switch self {
        case .account:         return "@"
        case .sessionBar:      return "5H"
        case .sessionBarPlain: return "5H"
        case .weeklyBar:       return "7D"
        case .weeklyBarPlain:  return "7D"
        case .dailyCost:       return "TODAY"
        case .sessionReset:    return "5H↻"
        case .weeklyReset:     return "7D↻"
        }
    }

    /// Human-readable name shown in the Settings reorder list.
    var localizedDisplayName: String {
        switch self {
        case .account:         return String(localized: "Account name", bundle: L10n.bundle)
        case .sessionBar:      return String(localized: "Session — usage vs time (5h)", bundle: L10n.bundle)
        case .sessionBarPlain: return String(localized: "Session usage (5h)", bundle: L10n.bundle)
        case .weeklyBar:       return String(localized: "Weekly — usage vs time (7d)", bundle: L10n.bundle)
        case .weeklyBarPlain:  return String(localized: "Weekly usage (7d)", bundle: L10n.bundle)
        case .dailyCost:       return String(localized: "Daily cost", bundle: L10n.bundle)
        case .sessionReset:    return String(localized: "Session reset countdown", bundle: L10n.bundle)
        case .weeklyReset:     return String(localized: "Weekly reset countdown", bundle: L10n.bundle)
        }
    }
}

/// Persistence helpers for the user's chosen module ordering.
enum MenuBarModuleStore {
    static let storageKey = "menuBarModules"
    static let migrationKey = "menuBarModulesMigratedV1"
    static let legacyShowAccountNameKey = "showAccountName"

    /// Decode resiliently: a single unknown/renamed rawValue (e.g. from a
    /// newer build or hand-edited prefs) must NOT wipe the whole list. We
    /// decode as `[String]` and keep the values that map to a known case.
    static func decode(_ data: Data) -> [MenuBarModule] {
        guard let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return raw.compactMap(MenuBarModule.init(rawValue:))
    }

    static func encode(_ modules: [MenuBarModule]) -> Data {
        (try? JSONEncoder().encode(modules)) ?? Data()
    }

    /// Seed the new storage on first launch (fresh install or not-yet-migrated
    /// upgrade). Idempotent — runs once and never clobbers an existing
    /// `menuBarModules` value (so users already on 1.8.x keep their config).
    ///
    /// Default for new/unconfigured users: account name + the plain session
    /// and weekly usage bars. Upgraders who had explicitly turned the legacy
    /// "show account name" toggle OFF wanted a minimal menu bar, so they get
    /// nothing (their intent is preserved).
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        // If real config already exists, just mark migrated and leave it alone.
        if defaults.data(forKey: storageKey) != nil {
            defaults.set(true, forKey: migrationKey)
            return
        }

        let legacy = defaults.object(forKey: legacyShowAccountNameKey) as? Bool ?? true
        let seed: [MenuBarModule] = legacy ? [.account, .sessionBarPlain, .weeklyBarPlain] : []
        defaults.set(encode(seed), forKey: storageKey)
        defaults.set(true, forKey: migrationKey)
    }
}
