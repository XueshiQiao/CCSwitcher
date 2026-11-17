import Foundation
import MoreAppsKit

/// The tabs of the Settings window, so code outside the window (the status
/// menu, the link on the About tab) can ask for one of them.
enum SettingsTab: Hashable {
    case general, menuBar, claudeCLI, moreApps, about
}

/// Which Settings tab is showing. One shared object because the Settings scene
/// is created by SwiftUI and nothing else holds a reference to its view.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
    private init() {}
}

/// The "More Apps" Settings tab: the author's other apps, each with a button
/// that downloads it, checks its signature, puts it in the Applications folder
/// and opens it. All of it comes from the shared MoreAppsKit package, which the
/// author's other apps embed too; this file only owns the package's model.
///
/// The model lives here, not in the Settings view, so a download keeps running
/// when the Settings window is closed.
///
/// No analytics: the package offers its events through `onEvent`, and this app
/// deliberately leaves that unset. CCSwitcher tells its users that only launch
/// counts are sent (see `Analytics`), and the More Apps events carry custom
/// properties.
@MainActor
enum MoreAppsHost {
    static let store = MoreAppsStore(
        configuration: .init(language: language(for: UserDefaults.standard.string(forKey: "appLanguage") ?? "auto")))

    /// The package's language for the app's language setting: `auto` follows
    /// the system, anything else is passed on as it is.
    static func language(for setting: String) -> String? {
        setting == "auto" ? nil : setting
    }
}
