import SwiftUI

/// Reusable capsule badge for status indicators (subscription type, active state, etc.).
struct Badge: View {
    let text: String
    let color: Color

    @Environment(\.panelStyle) private var style

    var body: some View {
        if style == .claude {
            // Quiet grey pill; status colors (active, expired) are kept.
            let ink = color == Theme.glow ? Theme.dim : color
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, AppStyle.badgeHPadding + 1)
                .padding(.vertical, AppStyle.badgeVPadding)
                .background(Capsule().fill(Theme.claudeSelected))
                .fixedSize()
        } else {
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .padding(.horizontal, AppStyle.badgeHPadding + 1)
                .padding(.vertical, AppStyle.badgeVPadding)
                .background(
                    Capsule()
                        .fill(color.opacity(0.14))
                        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
                )
                .fixedSize()
        }
    }
}
