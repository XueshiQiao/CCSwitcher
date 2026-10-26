import SwiftUI

// MARK: - Theme
//
// Claude palette (ivory / warm charcoal / terracotta) with soft layered
// surfaces and fluid motion. Every color adapts between light and dark.

enum Theme {
    // Palette
    static let accent = Color.brand
    static let accentDeep = Color(hexRGB: "#C15F3C") ?? .brand
    static let glow = Color.adaptive(light: Color(hexRGB: "#D97757")!, dark: Color(hexRGB: "#E58B6D")!)

    static let bgTop = Color.adaptive(light: Color(hexRGB: "#FAF9F5")!, dark: Color(hexRGB: "#30302E")!)
    static let bgBottom = Color.adaptive(light: Color(hexRGB: "#F0EEE6")!, dark: Color(hexRGB: "#1F1E1D")!)

    static let card = Color.adaptive(light: Color.white.opacity(0.72), dark: Color.white.opacity(0.055))
    static let cardHover = Color.adaptive(light: Color.white, dark: Color.white.opacity(0.09))
    static let well = Color.adaptive(light: Color(hexRGB: "#E8E6DC")!, dark: Color.black.opacity(0.35))

    static let text = Color.adaptive(light: Color(hexRGB: "#141413")!, dark: Color(hexRGB: "#FAF9F5")!)
    static let dim = Color.adaptive(light: Color(hexRGB: "#73726C")!, dark: Color(hexRGB: "#A6A39A")!)
    static let faint = Color.adaptive(light: Color(hexRGB: "#B0AEA5")!, dark: Color(hexRGB: "#5E5D59")!)
    static let hairline = Color.adaptive(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.08))
    static let highlight = Color.adaptive(light: Color.white.opacity(0.9), dark: Color.white.opacity(0.10))
    static let shadow = Color.adaptive(light: Color(hexRGB: "#5C4A3D")!.opacity(0.10), dark: Color.black.opacity(0.35))

    static let success = Color.adaptive(light: Color(hexRGB: "#5A8A4E")!, dark: Color(hexRGB: "#8DBF7F")!)
    static let warning = Color(hexRGB: "#E3A23B")!
    static let danger = Color.adaptive(light: Color(hexRGB: "#C2463B")!, dark: Color(hexRGB: "#E5675B")!)

    // Flat "Claude" panel style, after claude.ai's settings pages
    static let claudeBackground = Color.adaptive(light: Color(hexRGB: "#FAF9F5")!, dark: Color(hexRGB: "#262624")!)
    static let claudeCard = Color.adaptive(light: .white, dark: Color(hexRGB: "#30302E")!)
    static let claudeTrack = Color.adaptive(light: Color(hexRGB: "#E8E6DC")!, dark: Color.white.opacity(0.12))
    static let claudeBlue = Color.adaptive(light: Color(hexRGB: "#2C84DB")!, dark: Color(hexRGB: "#3B8FE8")!)
    static let claudeSelected = Color.adaptive(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.10))
    static let claudePrimary = Color.adaptive(light: Color(hexRGB: "#141413")!, dark: Color(hexRGB: "#FAF9F5")!)
    static let claudeOnPrimary = Color.adaptive(light: Color(hexRGB: "#FAF9F5")!, dark: Color(hexRGB: "#141413")!)

    // Translucent panel style: lighter fills so the glass shows through
    static let glassCard = Color.adaptive(light: Color.white.opacity(0.35), dark: Color.white.opacity(0.06))
    static let glassWell = Color.adaptive(light: Color.black.opacity(0.08), dark: Color.black.opacity(0.25))

    // Shape
    static let corner: CGFloat = 14
    static let pad: CGFloat = 16

    // Motion
    /// Strong ease-out (cubic-bezier 0.23, 1, 0.32, 1) for state changes.
    static let ease = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)
    /// Spring without bounce for interruptible, fluid motion.
    static let spring = Animation.spring(duration: 0.4, bounce: 0)
    /// Slow, soft spring for ambient changes (panel tint).
    static let gentle = Animation.spring(duration: 0.9, bounce: 0)
    static let snap = Animation.spring(duration: 0.3, bounce: 0.12)

    /// Accent gradient used for primary buttons, the tab indicator and avatars.
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [glow, accentDeep], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Panel environment

private struct PanelShownKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// True while the floating panel is on screen; drives the staggered entrance.
    var panelShown: Bool {
        get { self[PanelShownKey.self] }
        set { self[PanelShownKey.self] = newValue }
    }

    /// How the panel is drawn; see `PanelStyle`.
    var panelStyle: PanelStyle {
        get { self[PanelStyleKey.self] }
        set { self[PanelStyleKey.self] = newValue }
    }
}

/// How the popover panel is drawn (Settings > General > Appearance).
enum PanelStyle: String, CaseIterable, Identifiable {
    /// Warm ivory / charcoal with the terracotta bloom. The default.
    case warm
    /// The system popover material: the desktop shows through.
    case translucent
    /// Flat and neutral like claude.ai: solid background, plain cards,
    /// thin blue bars, no glow.
    case claude

    var id: String { rawValue }

    /// Big numbers are rounded in the warm styles and plain in the flat one.
    var numberDesign: Font.Design { self == .claude ? .default : .rounded }

    var title: LocalizedStringKey {
        switch self {
        case .warm: "Warm"
        case .translucent: "Translucent"
        case .claude: "Claude"
        }
    }
}

private struct PanelStyleKey: EnvironmentKey {
    static let defaultValue = PanelStyle.warm
}

// MARK: - Button style

/// Scale 0.96 on press, ease-out in, spring out.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Surface

/// Layered soft shadow + top-lit hairline instead of a hard border.
struct Surface: ViewModifier {
    var radius: CGFloat = Theme.corner
    var fill: Color = Theme.card

    @Environment(\.panelStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .claude:
            // Flat: solid card, hairline border, no highlight or shadow.
            content
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fill == Theme.card ? Theme.claudeCard : fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 0.5)
                        )
                )
        case .translucent:
            // A light veil over the glass; a shadow would muddy it.
            content
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fill == Theme.card ? Theme.glassCard : fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(colors: [Theme.highlight, Theme.hairline],
                                                   startPoint: .top, endPoint: .bottom),
                                    lineWidth: 0.5)
                        )
                )
        case .warm:
            styledSurface(content)
        }
    }

    private func styledSurface(_ content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [Theme.highlight, Theme.hairline],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 0.5)
                    )
                    .shadow(color: Theme.shadow, radius: 8, y: 3)
            )
    }
}

extension View {
    func surface(radius: CGFloat = Theme.corner, fill: Color = Theme.card) -> some View {
        modifier(Surface(radius: radius, fill: fill))
    }

    /// Padded card: the standard container for a section in the popover.
    func card(padding: CGFloat = 12, fill: Color = Theme.card) -> some View {
        self.padding(padding).surface(fill: fill)
    }
}

// MARK: - Entrance

private struct Enter: ViewModifier {
    var index: Int
    @Environment(\.panelShown) private var shown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .animation(
                shown
                    ? Theme.ease.delay(0.04 + Double(index) * 0.045)
                    : .easeIn(duration: 0.12),
                value: shown)
    }
}

extension View {
    /// Fade + rise + unblur, staggered by index, replayed each time the panel opens.
    func enter(_ index: Int) -> some View {
        modifier(Enter(index: index))
    }
}

// MARK: - Panel background

/// Warm ivory / charcoal panel with a soft terracotta bloom from the top.
/// The bloom warms toward red as the active session nears its limit.
/// `.translucent` swaps the solid base for the system popover material, so
/// the desktop shows through as it did with the old `NSPopover`; `.claude`
/// is a flat background with no bloom.
struct PanelBackground: View {
    var tint: Color = Theme.glow
    var intensity: Double = 1
    var style: PanelStyle = .warm

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if style == .claude {
            Theme.claudeBackground
        } else {
            bloom
        }
    }

    private var bloom: some View {
        let k = (scheme == .dark ? 1.0 : 0.7) * intensity
        return ZStack {
            if style == .translucent {
                VisualEffectBackground(material: .popover)
            } else {
                LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(colors: [tint.opacity(0.14 * k), tint.opacity(0.04 * k), .clear],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(0.22 * k), tint.opacity(0.07 * k), .clear],
                           center: .top, startRadius: 0, endRadius: 300)
                .scaleEffect(x: 2.4, y: 1.1, anchor: .top)
            RadialGradient(colors: [tint.opacity(0.06 * k), .clear],
                           center: .init(x: 0.5, y: 1.0), startRadius: 0, endRadius: 260)
        }
    }
}

/// Behind-window blur in the given system material.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // The panel never becomes the main window; keep the blur on anyway.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Maps session utilization (0…1) to the panel tint: calm terracotta, warming to red.
enum UsageTint {
    private static let stops: [(Double, Double, Double)] = [
        (0.851, 0.467, 0.341), // #D97757
        (0.851, 0.467, 0.341),
        (0.890, 0.420, 0.270),
        (0.870, 0.280, 0.250),
    ]

    static func at(_ f: Double) -> Color {
        let t = min(max(f, 0), 1) * Double(stops.count - 1)
        let i = min(Int(t), stops.count - 2)
        let k = t - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * k, green: a.1 + (b.1 - a.1) * k, blue: a.2 + (b.2 - a.2) * k)
    }
}

// MARK: - Shared pieces

/// Gradient circle with the account's initial (or provider glyph).
struct Avatar: View {
    var name: String
    var icon: String
    var active = true
    var size: CGFloat = 36

    @Environment(\.panelStyle) private var style

    private var initial: String? {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
    }

    var body: some View {
        let flat = style == .claude
        let ink: Color = flat ? Theme.text : (active ? .white : Theme.dim)
        ZStack {
            if flat {
                // Plain grey disc with the initial, like claude.ai's avatar.
                Circle()
                    .fill(Theme.claudeSelected)
            } else {
                Circle()
                    .fill(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.well))
                    .overlay(Circle().strokeBorder(Theme.highlight, lineWidth: 0.5))
                    .shadow(color: Theme.glow.opacity(active ? 0.35 : 0), radius: size * 0.3, y: 2)
            }
            if let initial {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: flat ? .default : .rounded))
                    .foregroundStyle(ink)
            } else {
                Image(systemName: icon)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(ink)
            }
        }
        .frame(width: size, height: size)
        .animation(Theme.ease, value: active)
    }
}

/// Small glowing status light; pulses while syncing.
struct StatusDot: View {
    enum State { case connected, syncing, idle, error }
    var state: State
    @SwiftUI.State private var pulse = false
    @Environment(\.panelStyle) private var style

    private var color: Color {
        switch state {
        case .connected: return Theme.success
        case .syncing: return Theme.glow
        case .idle: return Theme.faint
        case .error: return Theme.danger
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(state == .idle || style == .claude ? 0 : 0.7), radius: 3)
            .scaleEffect(state == .syncing && pulse ? 1.5 : 1)
            .opacity(state == .syncing && pulse ? 0.45 : 1)
            .animation(state == .syncing
                       ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                       : Theme.ease, value: pulse)
            .onAppear { pulse = state == .syncing }
            .onChange(of: state) { _, s in pulse = s == .syncing }
    }
}

/// Circular icon button on a surface, with hover lift. Shows a spinner while `busy`.
struct CircleIconButton: View {
    var icon: String
    var size: CGFloat = 30
    var tint: Color = Theme.dim
    var busy = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(size < 30 ? 0.7 : 0.8)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(hover ? Theme.text : tint)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(width: size, height: size)
            .surface(radius: size / 2, fill: hover ? Theme.cardHover : Theme.card)
            .contentShape(Circle())
            .animation(Theme.ease, value: busy)
        }
        .buttonStyle(PressStyle())
        .focusable(false)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Primary call-to-action: terracotta gradient pill with a soft glow.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    var fillsWidth = false

    @Environment(\.panelStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        if style == .claude {
            // claude.ai's primary button: solid ink, no gradient or glow.
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.claudeOnPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14)
                .frame(minHeight: height)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.claudePrimary.opacity(configuration.isPressed ? 0.8 : 1))
                )
        } else {
            warmBody(configuration)
        }
    }

    private func warmBody(_ configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: !fillsWidth, vertical: false)
            .padding(.horizontal, 14)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: height / 2.6, style: .continuous)
                    .fill(Theme.accentGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: height / 2.6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: Theme.glow.opacity(configuration.isPressed ? 0.2 : 0.35), radius: 10, y: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16), value: configuration.isPressed)
    }
}

/// Secondary action: quiet surface pill.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32

    @Environment(\.panelStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, design: style == .claude ? .default : .rounded).weight(.medium))
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .surface(radius: height / 2.6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16), value: configuration.isPressed)
    }
}

/// Recessed track with a glowing gradient fill that grows in on appear.
struct GlowBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 8
    /// Optional elapsed-time marker (0…1).
    var marker: Double?

    @State private var grown = false
    @Environment(\.panelStyle) private var style

    var body: some View {
        GeometryReader { geo in
            let f = grown ? min(max(fraction, 0), 1) : 0
            let w = geo.size.width * f
            ZStack(alignment: .leading) {
                let flat = style == .claude
                Capsule()
                    .fill(flat ? Theme.claudeTrack : (style == .translucent ? Theme.glassWell : Theme.well))
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: flat ? 0 : 0.5))
                Capsule()
                    .fill(flat
                          ? AnyShapeStyle(color)
                          : AnyShapeStyle(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing)))
                    .frame(width: f > 0 ? max(w, height) : 0)
                    .shadow(color: flat ? .clear : color.opacity(0.45), radius: 5)
                if let marker {
                    Capsule()
                        .fill(Theme.text.opacity(0.55))
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * min(max(marker, 0), 1) - 1)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 4)
        .animation(Theme.spring, value: fraction)
        .animation(.spring(duration: 0.9, bounce: 0).delay(0.15), value: grown)
        .onAppear { grown = true }
    }
}

/// Uppercase section label used above groups of cards.
struct SectionLabel: View {
    var title: LocalizedStringKey
    var trailing: String?

    @Environment(\.panelStyle) private var style

    var body: some View {
        HStack {
            if style == .claude {
                // Sentence-case heading, like claude.ai's settings sections.
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
            } else {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: style == .claude ? 12 : 10.5, weight: .medium,
                                  design: style == .claude ? .default : .rounded).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 4)
    }
}
