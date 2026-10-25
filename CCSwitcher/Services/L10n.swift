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
        locale(for: UserDefaults.standard.string(forKey: "appLanguage") ?? "auto")
    }

    /// The chosen language with the system's region kept, so numbers, money
    /// and dates still follow local conventions: Spanish on a Guatemalan Mac
    /// writes "USD 1.23", not Spain's "1,23 US$".
    static func locale(for lang: String) -> Locale {
        if lang == "auto" { return .autoupdatingCurrent }
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: lang) }
        return Locale(identifier: "\(lang)_\(region)")
    }
}
