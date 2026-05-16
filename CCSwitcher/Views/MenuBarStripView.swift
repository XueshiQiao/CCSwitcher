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
    // view). We poll on a short interval instead.
    let appState: AppState
    let config: MenuBarConfig
    let onWidth: (CGFloat) -> Void
    @AppStorage("showFullEmail") private var showFullEmail = false

    @State private var tick = Date()
    @State private var iconFilled = false
    // Polled refresh. ObservableObject change delivery is unreliable for a
    // SwiftUI view hosted in an NSStatusItem, so we re-read AppState/config on
    // a short interval (the pattern menu-bar monitors like iStats/Stats use).
    // This also keeps the reset countdowns current.
    private let tickTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconFilled ? "brain.head.profile.fill" : "brain.head.profile")
                .font(.system(size: 14))

            ForEach(config.modules) { module in
                MenuBarModuleView(
                    module: module,
                    appState: appState,
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
