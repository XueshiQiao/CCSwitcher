import Foundation
import SwiftUI

enum LimitBarKind {
    case session
    case weekly
}

/// Shared, reactive source of truth for the menu-bar module list.
///
/// We use an `ObservableObject` instead of `@AppStorage(Data)` because
/// `@AppStorage` reactivity for `Data`-typed bindings is unreliable across
/// SwiftUI scenes (Settings scene writes; MenuBarExtra scene must observe).
/// A single `@MainActor` store, observed by both scenes, guarantees both
/// stay in sync without round-tripping through UserDefaults KVO.
///
/// State is persisted to `UserDefaults` so it survives app restarts; the
/// `@Published modules` array is the live source consumed by views.
@MainActor
final class MenuBarConfig: ObservableObject {
    static let shared = MenuBarConfig()
    static let defaultSessionLimitBarColorHex = "#34C759"
    static let defaultWeeklyLimitBarColorHex = "#0A84FF"
    static let defaultLowRemainingLimitBarColorHex = "#FF3B30"
    static let defaultLowRemainingThreshold = 30.0

    @Published var modules: [MenuBarModule] {
        didSet { persist() }
    }

    @Published var showsHeadIcon: Bool {
        didSet { persistShowsHeadIcon() }
    }

    @Published var sessionLimitBarColorHex: String {
        didSet { persistSessionLimitBarColor() }
    }

    @Published var weeklyLimitBarColorHex: String {
        didSet { persistWeeklyLimitBarColor() }
    }

    @Published var lowRemainingLimitBarColorHex: String {
        didSet { persistLowRemainingLimitBarColor() }
    }

    @Published var lowRemainingWarningThreshold: Double {
        didSet { persistLowRemainingWarningThreshold() }
    }

    private let storageKey = MenuBarModuleStore.storageKey
    private let showsHeadIconKey = "menuBarShowsHeadIcon"
    private let sessionLimitBarColorKey = "sessionLimitBarColor"
    private let weeklyLimitBarColorKey = "weeklyLimitBarColor"
    private let lowRemainingLimitBarColorKey = "lowRemainingLimitBarColor"
    private let lowRemainingWarningThresholdKey = "lowRemainingWarningThreshold"

    private init() {
        // Migration must run BEFORE the first read so a fresh-after-upgrade
        // launch sees the seeded default instead of an empty list.
        MenuBarModuleStore.migrateIfNeeded()
        let data = UserDefaults.standard.data(forKey: storageKey) ?? Data()
        self.modules = MenuBarModuleStore.decode(data)
        if UserDefaults.standard.object(forKey: showsHeadIconKey) == nil {
            self.showsHeadIcon = true
        } else {
            self.showsHeadIcon = UserDefaults.standard.bool(forKey: showsHeadIconKey)
        }
        self.sessionLimitBarColorHex = UserDefaults.standard.string(forKey: sessionLimitBarColorKey)
            ?? Self.defaultSessionLimitBarColorHex
        self.weeklyLimitBarColorHex = UserDefaults.standard.string(forKey: weeklyLimitBarColorKey)
            ?? Self.defaultWeeklyLimitBarColorHex
        self.lowRemainingLimitBarColorHex = UserDefaults.standard.string(forKey: lowRemainingLimitBarColorKey)
            ?? Self.defaultLowRemainingLimitBarColorHex
        if let threshold = UserDefaults.standard.object(forKey: lowRemainingWarningThresholdKey) as? Double {
            self.lowRemainingWarningThreshold = threshold
        } else {
            self.lowRemainingWarningThreshold = Self.defaultLowRemainingThreshold
        }
    }

    private func persist() {
        UserDefaults.standard.set(MenuBarModuleStore.encode(modules), forKey: storageKey)
    }

    private func persistShowsHeadIcon() {
        UserDefaults.standard.set(showsHeadIcon, forKey: showsHeadIconKey)
    }

    private func persistSessionLimitBarColor() {
        UserDefaults.standard.set(sessionLimitBarColorHex, forKey: sessionLimitBarColorKey)
    }

    private func persistWeeklyLimitBarColor() {
        UserDefaults.standard.set(weeklyLimitBarColorHex, forKey: weeklyLimitBarColorKey)
    }

    private func persistLowRemainingLimitBarColor() {
        UserDefaults.standard.set(lowRemainingLimitBarColorHex, forKey: lowRemainingLimitBarColorKey)
    }

    private func persistLowRemainingWarningThreshold() {
        UserDefaults.standard.set(lowRemainingWarningThreshold, forKey: lowRemainingWarningThresholdKey)
    }

    /// Replace the current list. Used by the Settings editor on reorder / toggle.
    func set(_ modules: [MenuBarModule]) {
        // Dedup while preserving order — defends against stale UserDefaults data
        // that could otherwise produce duplicate `ForEach` identities.
        var seen = Set<MenuBarModule>()
        let deduped = modules.filter { seen.insert($0).inserted }
        guard deduped != self.modules else { return } // skip no-op churn
        self.modules = deduped
    }

    var sessionLimitBarColor: Color {
        Self.color(from: sessionLimitBarColorHex, fallback: Self.defaultSessionLimitBarColorHex)
    }

    var weeklyLimitBarColor: Color {
        Self.color(from: weeklyLimitBarColorHex, fallback: Self.defaultWeeklyLimitBarColorHex)
    }

    var lowRemainingLimitBarColor: Color {
        Self.color(from: lowRemainingLimitBarColorHex, fallback: Self.defaultLowRemainingLimitBarColorHex)
    }

    func limitBarColor(for kind: LimitBarKind, utilization: Double?) -> Color {
        if let utilization {
            let remaining = 100.0 - min(max(utilization, 0), 100)
            let threshold = min(max(lowRemainingWarningThreshold, 0), 100)
            if remaining <= threshold {
                return lowRemainingLimitBarColor
            }
        }

        switch kind {
        case .session:
            return sessionLimitBarColor
        case .weekly:
            return weeklyLimitBarColor
        }
    }

    private static func color(from hex: String, fallback: String) -> Color {
        Color(hexRGB: hex) ?? Color(hexRGB: fallback) ?? .brand
    }
}
