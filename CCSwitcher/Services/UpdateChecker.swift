import Foundation
import AppKit
import Sparkle
import SwiftUI

/// Thin ObservableObject wrapper around Sparkle's `SPUStandardUpdaterController`.
/// Keeps the existing call-site API (`checkForUpdates(manual:)`,
/// `@Published var isChecking`) so `CCSwitcherApp.swift` and `SettingsView.swift`
/// don't need to change. Sparkle owns its own progress UI (download sheet,
/// release-notes window, restart prompt), so `isChecking` is kept for source
/// compatibility but is never flipped — clicking the button always shows
/// Sparkle's UI immediately, which provides its own feedback.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Source-compat shim. Sparkle's UI is responsible for visible progress.
    @Published var isChecking = false

    private let controller: SPUStandardUpdaterController

    init() {
        // Configure before starting: even a saved opt-in must not schedule checks.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
    }

    /// Manual = user-initiated; shows Sparkle's full UI including
    /// "you're up to date" feedback when no update is available.
    /// Background checks are disabled; initialize Sparkle only on an explicit click.
    func checkForUpdates(manual: Bool = false) {
        guard manual else { return }
        controller.startUpdater()
        controller.checkForUpdates(nil)
    }
}
