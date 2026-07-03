import AppKit
import Foundation
import SwiftUI

extension Color {
    /// CCSwitcher brand color.
    // static let brand = Color(red: 0x7C / 255.0, green: 0x3A / 255.0, blue: 0xED / 255.0) // #7C3AED
    static let brand = Color(red: 0xE8 / 255.0, green: 0x6D / 255.0, blue: 0x45 / 255.0) // #E86D45

    /// Creates a color that automatically adapts between light and dark appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }

    init?(hexRGB: String) {
        let trimmed = hexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    var hexRGB: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }

        func channel(_ component: CGFloat) -> Int {
            min(max(Int(round(component * 255)), 0), 255)
        }

        return String(
            format: "#%02X%02X%02X",
            channel(rgb.redComponent),
            channel(rgb.greenComponent),
            channel(rgb.blueComponent)
        )
    }

    // MARK: - Card

    /// Standard card fill.
    static let cardFill = adaptive(light: Color.white.opacity(0.20), dark: Color.black.opacity(0.21))
    /// Emphasized card fill (e.g. active account row).
    static let cardFillStrong = adaptive(light: Color.white.opacity(0.25), dark: Color.black.opacity(0.28))
    /// Standard card border.
    static let cardBorder = adaptive(light: Color.white.opacity(0.40), dark: Color.white.opacity(0.20))

    // MARK: - Tab Bar

    /// Tab bar background fill.
    static let tabFill = adaptive(light: Color.white.opacity(0.15), dark: Color.black.opacity(0.21))
    /// Tab bar border.
    static let tabBorder = adaptive(light: Color.white.opacity(0.40), dark: Color.white.opacity(0.20))

    // MARK: - Text

    /// Primary text color for cards and tab selected state.
    static let textPrimary = adaptive(light: Color.primary, dark: Color.white)
    /// Secondary text color for card labels and tab unselected state.
    static let textSecondary = adaptive(light: Color.secondary, dark: Color.white.opacity(0.55))

    // MARK: - Subtle Backgrounds

    /// Subtle brand tint for banners and badges.
    static let subtleBrand = adaptive(light: brand.opacity(0.12), dark: brand.opacity(0.28))
    /// Progress bar track.
    static let progressTrack = adaptive(light: Color.gray.opacity(0.18), dark: Color.white.opacity(0.15))
}

extension ShapeStyle where Self == Color {
    static var brand: Color { .brand }
    static var cardFill: Color { .cardFill }
    static var cardFillStrong: Color { .cardFillStrong }
    static var cardBorder: Color { .cardBorder }
    static var tabFill: Color { .tabFill }
    static var tabBorder: Color { .tabBorder }
    static var textPrimary: Color { .textPrimary }
    static var textSecondary: Color { .textSecondary }
    static var subtleBrand: Color { .subtleBrand }
    static var progressTrack: Color { .progressTrack }
}
