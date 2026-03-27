import SwiftUI

extension Color {
    /// CCSwitcher brand color.
    static let brand = Color(red: 0xFF / 255.0, green: 0xC8 / 255.0, blue: 0x00 / 255.0) // #FFC800
}

extension ShapeStyle where Self == Color {
    static var brand: Color { .brand }
}
