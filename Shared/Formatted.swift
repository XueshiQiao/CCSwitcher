import Foundation

/// Locale-aware renderings shared by the app and the widget, so money and
/// percentages read the way the user's language writes them.
enum Formatted {
    /// A US-dollar cost. Cents from $1 up; four decimals below that, so small
    /// amounts don't all collapse to "$0.00".
    static func cost(_ cost: Double, locale: Locale) -> String {
        cost.formatted(.currency(code: "USD")
            .precision(.fractionLength(cost >= 1 ? 2 : 4))
            .locale(locale))
    }

    /// A 0–100 value as a whole percentage, truncated like the bars are
    /// (89.9 stays "89%", never a premature "90%").
    static func percent(_ value: Double, locale: Locale) -> String {
        (Double(Int(value)) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// A "yyyy-MM-dd" day key as a short month/day in the locale's order.
    static func shortDay(_ dayKey: String, locale: Locale) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: dayKey) else { return dayKey }
        let out = DateFormatter()
        out.locale = locale
        out.setLocalizedDateFormatFromTemplate("Md")
        return out.string(from: date)
    }
}
