import SwiftUI

extension Color {
    /// CCSwitcher brand color.
    static let brand = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0) // #d97757
}

extension ShapeStyle where Self == Color {
    static var brand: Color { .brand }
}
