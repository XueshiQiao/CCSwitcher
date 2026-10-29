import SwiftUI

private let popoverLog = FileLog("Popover")

// MARK: - Popover Height Measurement
//
// The popover frame adapts to the natural height of the Usage tab's content
// plus the surrounding chrome (header, tab bar, footer). Both are MEASURED
// via SwiftUI PreferenceKeys so the layout stays correct when fonts,
// paddings, localization, or content change — no hardcoded layout numbers.
//
// Contract for future contributors:
//   * Every chrome element in MainMenuView.body must call `.measureChromeHeight()`.
//     Currently: headerView, promoBanner (when shown), tabBar, footerView.
//   * UsageDashboardView's scrollable content must call `.measureUsageContentHeight()`
//     on its inner VStack (the one inside the ScrollView, not the ScrollView itself).
//   * The Divider between content and footer is intentionally not measured
//     (1pt constant, accounted for in the formula).

/// Reports the intrinsic height of the Usage tab's inner content.
/// Uses `max` reduce so only the currently visible measurement wins.
struct UsageContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the summed height of all chrome elements in MainMenuView.
/// Uses `+=` reduce to aggregate header + tabBar + footer (etc.) into one value.
struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

extension View {
    /// Report this view's height as Usage tab content.
    /// Apply to the inner VStack of the Usage tab (inside its ScrollView).
    func measureUsageContentHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: UsageContentHeightKey.self,
                    value: geo.size.height
                )
            }
        )
    }

    /// Report this view's height as chrome (header/tabBar/footer/etc.).
    /// Apply to every non-content element in MainMenuView.body.
    func measureChromeHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ChromeHeightKey.self,
                    value: geo.size.height
                )
            }
        )
    }
}

/// The main popover content shown when clicking the menubar icon.
struct MainMenuView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("showFullEmail") private var showFullEmail = false
    @Namespace private var tabIndicator
    @Environment(\.panelStyle) private var panelStyle
    /// Holds the selected tab and the measured heights, which outlive this
    /// view: the panel unmounts it while hidden.
    let panel: PanelModel

    enum Tab: String, CaseIterable {
        case usage, costs, accounts

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .usage: "Usage"
            case .costs: "Costs"
            case .accounts: "Accounts"
            }
        }

        var iconName: String {
            switch self {
            case .usage: "chart.bar.fill"
            case .costs: "dollarsign.circle.fill"
            case .accounts: "person.2.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .measureChromeHeight()
                .enter(0)

            if isPromoActive() {
                promoBannerView
                    .measureChromeHeight()
                    .enter(1)
            }

            // Tab selector
            tabBar
                .measureChromeHeight()
                .enter(1)

            // Content
            Group {
                switch panel.selectedTab {
                case .usage:
                    UsageDashboardView()
                case .costs:
                    CostDetailView()
                case .accounts:
                    AccountSwitcherView()
                }
            }
            .id(panel.selectedTab)
            .transition(.opacity.combined(with: .offset(y: 6)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .enter(2)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.horizontal, Theme.pad)

            // Footer
            footerView
                .measureChromeHeight()
                .enter(3)
        }
        .frame(width: 360, height: popoverHeight)
        .animation(Theme.spring, value: popoverHeight)
        .foregroundStyle(Theme.text)
        .fontDesign(panelStyle == .claude ? .default : .rounded)
        .background(
            // Probe: report the actual rendered size of the outer VStack
            // (after .frame is applied). If this doesn't match popoverHeight,
            // we have a frame-not-applied problem; if it matches but the
            // panel is still bigger, the issue is the panel itself.
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        popoverLog.info("[actual] vstack size=\(geo.size.width)x\(geo.size.height)")
                    }
                    .onChange(of: geo.size) { _, new in
                        popoverLog.info("[actual] vstack size=\(new.width)x\(new.height)")
                    }
            }
        )
        .onAppear {
            popoverLog.info("[appear] tab=\(self.panel.selectedTab.rawValue) chrome=\(self.panel.chromeHeight) usage=\(self.panel.usageContentHeight) popover=\(self.popoverHeight)")
        }
        .onPreferenceChange(UsageContentHeightKey.self) { value in
            if value > 0 { panel.usageContentHeight = value }
        }
        .onPreferenceChange(ChromeHeightKey.self) { value in
            if value > 0 { panel.chromeHeight = value }
        }
        // Explicitly observe popoverHeight so SwiftUI tracks the computed
        // value as a dependency of the .frame modifier above. Without this,
        // some Release builds appear to skip the frame update when only the
        // underlying heights (chromeHeight / usageContentHeight) change —
        // the panel locks at the initial-render height and shows the
        // visible empty bands users reported in 1.5.3.
        .onChange(of: popoverHeight) { _, new in
            popoverLog.info("[height] popover=\(new)")
        }
    }

    // MARK: - Dynamic Popover Height

    /// See `PanelModel.popoverHeight`, which the hidden panel sizes itself by.
    private var popoverHeight: CGFloat { panel.popoverHeight }

    // MARK: - Promo Banner

    private var promoBannerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "gift.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.glow)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accent.opacity(0.14)))

            VStack(alignment: .leading, spacing: 1) {
                Text("Double Usage Active")
                    .font(.caption.weight(.semibold))
                Text(localOffPeakTimeString)
                    .font(.caption2)
                    .foregroundStyle(Theme.dim)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .surface(fill: Theme.accent.opacity(0.10))
        .padding(.horizontal, Theme.pad)
        .padding(.bottom, 10)
    }

    private func isPromoActive() -> Bool {
        // Banner visibility tracks the campaign window; the menu-bar icon uses
        // `DoubleUsagePromo.isActive` for the currently-doubled state. Both now
        // share one source of truth (no duplicated date logic).
        DoubleUsagePromo.isCampaignActive()
    }
    
    private var localOffPeakTimeString: String {
        guard let etTimeZone = TimeZone(identifier: "America/New_York") else {
            return String(localized: "Double limits: 2 PM - 8 AM ET & Weekends", bundle: L10n.bundle)
        }

        let today = Date()
        var etCalendar = Calendar(identifier: .gregorian)
        etCalendar.timeZone = etTimeZone

        // The double usage starts at 2:00 PM (14:00) ET and ends at 8:00 AM ET next day
        guard let etStartOffPeak = etCalendar.date(bySettingHour: 14, minute: 0, second: 0, of: today),
              let etEndOffPeak = etCalendar.date(bySettingHour: 8, minute: 0, second: 0, of: today) else {
            return String(localized: "Double limits: 2 PM - 8 AM ET & Weekends", bundle: L10n.bundle)
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = TimeZone.current

        let localStart = formatter.string(from: etStartOffPeak)
        let localEnd = formatter.string(from: etEndOffPeak)

        return String(localized: "\(localStart) - \(localEnd) (Weekdays) & Weekends", bundle: L10n.bundle)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            if let account = appState.activeAccount {
                Avatar(name: account.effectiveDisplayName(obfuscated: !showFullEmail),
                       icon: account.provider.iconName, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if let sub = account.displaySubscriptionType {
                            Badge(text: sub, color: Theme.glow)
                        }
                    }
                    HStack(spacing: 6) {
                        StatusDot(state: status)
                        Text(account.displayEmail(obfuscated: !showFullEmail))
                            .font(.caption)
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                }
            } else {
                Avatar(name: "", icon: "brain.head.profile", active: false, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("CCSwitcher")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        StatusDot(state: status)
                        Text("No account connected")
                            .font(.caption)
                            .foregroundStyle(Theme.dim)
                    }
                }
            }

            Spacer(minLength: 8)

            CircleIconButton(icon: "arrow.clockwise", size: 32, busy: appState.isLoading) {
                Task { await appState.refresh() }
            }
            .help("Refresh")
        }
        .padding(.horizontal, Theme.pad)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var status: StatusDot.State {
        if appState.errorMessage != nil { return .error }
        if appState.isLoading { return .syncing }
        return appState.activeAccount == nil ? .idle : .connected
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                TabButton(
                    title: tab.localizedTitle,
                    icon: tab.iconName,
                    selected: panel.selectedTab == tab,
                    namespace: tabIndicator
                ) {
                    withAnimation(Theme.spring) { panel.selectedTab = tab }
                }
            }
        }
        .padding(3)
        .background {
            switch panelStyle {
            case .claude:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.claudeCard)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5))
            case .translucent:
                Capsule()
                    .fill(Theme.glassWell)
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            case .warm, .classic:  // Classic never shows this view.
                Capsule()
                    .fill(Theme.well)
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.bottom, 6)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            if let error = appState.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .font(.caption)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            } else if let lastRefresh = appState.lastUsageRefresh {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
                Text(lastRefresh, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }

            Spacer()

            CircleIconButton(icon: "gearshape", size: 26) {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .ccswitcherOpenSettings,
                    object: nil
                )
            }
            .help("Settings")

            CircleIconButton(icon: "power", size: 26) {
                NSApplication.shared.terminate(nil)
            }
            .help("Quit")
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 10)
    }
}

/// One segment of the tab bar; the selected one carries the sliding terracotta pill.
private struct TabButton: View {
    var title: LocalizedStringKey
    var icon: String
    var selected: Bool
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hover = false
    @Environment(\.panelStyle) private var style

    var body: some View {
        let flat = style == .claude
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: flat ? .medium : .semibold, design: flat ? .default : .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? (flat ? Theme.text : .white) : (hover ? Theme.text : Theme.dim))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                if selected {
                    if flat {
                        // claude.ai's selected row: a plain grey fill.
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.claudeSelected)
                            .matchedGeometryEffect(id: "tab", in: namespace)
                    } else {
                        Capsule()
                            .fill(Theme.accentGradient)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                            .shadow(color: Theme.glow.opacity(0.35), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "tab", in: namespace)
                    }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .focusable(false)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}
