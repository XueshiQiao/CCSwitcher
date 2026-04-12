import Foundation

/// Provides the correct localization bundle and locale based on the user's in-app language preference.
enum L10n {
    /// The bundle for the user's chosen language, used with `String(localized:bundle:)`.
    static var bundle: Bundle {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        guard lang != "auto",
              let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    /// The locale for the user's chosen language, used with `.environment(\.locale, ...)`.
    static var locale: Locale {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        if lang == "auto" { return .autoupdatingCurrent }
        return Locale(identifier: lang)
    }
}
