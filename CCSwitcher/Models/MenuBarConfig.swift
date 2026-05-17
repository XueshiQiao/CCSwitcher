import Foundation
import SwiftUI

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

    @Published var modules: [MenuBarModule] {
        didSet { persist() }
    }

    private let storageKey = MenuBarModuleStore.storageKey

    private init() {
        // Migration must run BEFORE the first read so a fresh-after-upgrade
        // launch sees the seeded default instead of an empty list.
        MenuBarModuleStore.migrateIfNeeded()
        let data = UserDefaults.standard.data(forKey: storageKey) ?? Data()
        self.modules = MenuBarModuleStore.decode(data)
    }

    private func persist() {
        UserDefaults.standard.set(MenuBarModuleStore.encode(modules), forKey: storageKey)
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
}
