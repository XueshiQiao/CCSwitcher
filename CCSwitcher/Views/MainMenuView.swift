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
    @State private var selectedTab: Tab = .usage

    // Measured heights driving the popover frame.
    // Defaults are reasonable fallbacks for the first render pass, before
    // the GeometryReader-based measurements fire.
    @State private var usageContentHeight: CGFloat = 420
    @State private var chromeHeight: CGFloat = 180

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

            if isPromoActive() {
                promoBannerView
                    .measureChromeHeight()
            }

            // Tab selector
            tabBar
                .measureChromeHeight()

            // Content
            Group {
                switch selectedTab {
                case .usage:
                    UsageDashboardView()
                case .costs:
                    CostDetailView()
                case .accounts:
                    AccountSwitcherView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            footerView
                .measureChromeHeight()
        }
        .frame(width: 360, height: popoverHeight)
        .animation(.easeInOut(duration: 0.2), value: popoverHeight)
        .background(
            // Probe: report the actual rendered size of the outer VStack
            // (after .frame is applied). If this doesn't match popoverHeight,
            // we have a frame-not-applied problem; if it matches but the
            // popover panel is still bigger, the issue is the panel itself.
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
        .background(.ultraThinMaterial)
        .onAppear {
            popoverLog.info("[appear] tab=\(self.selectedTab.rawValue) chrome=\(self.chromeHeight) usage=\(self.usageContentHeight) popover=\(self.popoverHeight)")
        }
        .onPreferenceChange(UsageContentHeightKey.self) { value in
            if value > 0 { usageContentHeight = value }
        }
        .onPreferenceChange(ChromeHeightKey.self) { value in
            if value > 0 { chromeHeight = value }
        }
        // Explicitly observe popoverHeight so SwiftUI tracks the computed
        // value as a dependency of the .frame modifier above. Without this,
        // some Release builds appear to skip the frame update when only the
        // underlying @State (chromeHeight / usageContentHeight) changes —
        // the panel locks at the initial-render height and shows the
        // visible empty bands users reported in 1.5.3.
        .onChange(of: popoverHeight) { _, new in
            popoverLog.info("[height] popover=\(new)")
        }
    }

    // MARK: - Dynamic Popover Height

    /// Popover height is driven by measured Usage tab content + measured chrome.
    /// The Usage tab is chosen as the height reference because it's the
    /// content-heaviest tab; sizing for it gives other tabs enough headroom.
    /// Capped only by available screen space; no artificial floor — the popover
    /// matches its content exactly, so there is no padding gap inside the
    /// ScrollView when content is short.
    private var popoverHeight: CGFloat {
        let screenCap: CGFloat = (NSScreen.main?.visibleFrame.height ?? 900) - 100
        let maxHeight: CGFloat = min(900, screenCap)

        // +1 for the Divider between content and footer (not measured).
        let desired = chromeHeight + usageContentHeight + 1

        return min(maxHeight, desired)
    }

    // MARK: - Promo Banner
    
    private var promoBannerView: some View {
        HStack {
            Image(systemName: "gift.fill")
                .foregroundStyle(.brand)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Double Usage Active")
                    .font(.caption)
                    .fontWeight(.medium)
                Text(localOffPeakTimeString)
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.subtleBrand)
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
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.brand)

            VStack(alignment: .leading, spacing: 3) {
                if let account = appState.activeAccount {
                    HStack(spacing: 6) {
                        Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                            .font(.headline)
                        if let sub = account.displaySubscriptionType {
                            Badge(text: sub, color: .brand)
                        }
                    }
                    Text(account.displayEmail(obfuscated: !showFullEmail))
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                } else {
                    Text("CCSwitcher")
                        .font(.headline)
                    Text("No account connected")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }

            Spacer()

            if appState.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ZStack {
            // Background capsule
            Capsule()
                .fill(.tabFill)
                .overlay(Capsule().stroke(.tabBorder, lineWidth: 1))

            // Sliding indicator
            GeometryReader { geo in
                let count = CGFloat(Tab.allCases.count)
                let tabWidth = geo.size.width / count
                let index = CGFloat(Tab.allCases.firstIndex(of: selectedTab) ?? 0)
                Capsule()
                    .fill(Color.brand)
                    .padding(2)
                    .frame(width: tabWidth)
                    .offset(x: tabWidth * index)
                    .animation(.easeInOut(duration: 0.15), value: selectedTab)
            }

            // Tab labels on top
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    VStack(spacing: 2) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 12))
                        Text(tab.localizedTitle)
                            .font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selectedTab == tab ? .white : .textSecondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }
                }
            }
        }
        .frame(width: 260, height: 44)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if let error = appState.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await appState.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Refresh")

            Button {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .ccswitcherOpenSettings,
                    object: nil
                )
            } label: {
                Image(systemName: "gear")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Quit")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
