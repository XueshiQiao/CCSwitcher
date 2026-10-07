import SwiftUI

// MARK: - Design Tokens

enum AppStyle {
    // Layout
    static let cardCornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let screenHorizontalPadding: CGFloat = 12

    // Shadow
    static let cardShadowColor = Color.black.opacity(0.04)
    static let cardShadowRadius: CGFloat = 2
    static let cardShadowY: CGFloat = 1

    // Badge
    static let badgeHPadding: CGFloat = 6
    static let badgeVPadding: CGFloat = 2

    // Progress Bar
    static let barCornerRadius: CGFloat = 3
    static let barHeight: CGFloat = 7

    // Colors
    static let buttonTextColor = Color(red: 0x42 / 255, green: 0x42 / 255, blue: 0x42 / 255)
}

// MARK: - Card Style Modifier

struct CardStyleModifier: ViewModifier {
    var fill: Color = .cardFill
    var border: Color = .cardBorder
    var hasShadow: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(AppStyle.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius)
                    .fill(fill)
                    .strokeBorder(border, lineWidth: 1)
                    .shadow(
                        color: hasShadow ? AppStyle.cardShadowColor : .clear,
                        radius: AppStyle.cardShadowRadius,
                        x: 0,
                        y: AppStyle.cardShadowY
                    )
            )
    }
}

extension View {
    /// Standard card style with fill, border, shadow, and content padding.
    func cardStyle(fill: Color = .cardFill, border: Color = .cardBorder, hasShadow: Bool = true) -> some View {
        modifier(CardStyleModifier(fill: fill, border: border, hasShadow: hasShadow))
    }

    /// Standard horizontal padding for sections within the popover.
    func sectionPadding() -> some View {
        padding(.horizontal, AppStyle.screenHorizontalPadding)
    }
}
