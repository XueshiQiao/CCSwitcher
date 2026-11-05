import SwiftUI

private struct StripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The full content rendered inside the `NSStatusItem` button: the app icon
/// followed by every enabled module, laid out horizontally. Each module is a
/// two-line iStats-style cell. Hosted in an `NSHostingController` so it is free
/// of `MenuBarExtra`'s single-line / single-element label constraints.
///
/// The view reports its intrinsic width via `onWidth` so the controller can
/// keep `NSStatusItem.length` exactly matched — otherwise the status item
/// keeps a stale (too-narrow) width and clips the leading icon / trailing
/// module once real data widens the content.
struct MenuBarStripView: View {
    // Not @ObservedObject: in the NSStatusItem hosting context, ObservableObject
    // change delivery is unreliable (only @State / timer re-render the hosted
    // view). StatusItemController rebuilds this view on every change instead.
    let appState: AppState
    let config: MenuBarConfig
    let onWidth: (CGFloat) -> Void
    @AppStorage("showFullEmail") private var showFullEmail = false

    @State private var tick = Date()
    @State private var iconFilled = false
    // Keeps the reset countdowns and pace markers current. State changes no
    // longer depend on it (StatusItemController rebuilds the view on each
    // one), and the countdowns are minute-granular, so once a minute is
    // enough; the tolerance lets the system coalesce the wake-up.
    private let tickTimer = Timer.publish(every: 60, tolerance: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            if config.showsHeadIcon {
                Image(systemName: iconFilled ? "brain.head.profile.fill" : "brain.head.profile")
                    .font(.system(size: 14))
            }

            ForEach(config.modules) { module in
                MenuBarModuleView(
                    module: module,
                    appState: appState,
                    config: config,
                    showFullEmail: showFullEmail,
                    tick: tick
                )
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .fixedSize()
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: StripWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(StripWidthKey.self) { width in
            if width > 0 { onWidth(width) }
        }
        .onReceive(tickTimer) { date in
            tick = date
            iconFilled = DoubleUsagePromo.isActive(at: date)
        }
        .onAppear { iconFilled = DoubleUsagePromo.isActive(at: Date()) }
    }
}
