import SwiftUI

private let popoverLog = FileLog("Popover")

/// The 1.x popover content, shown when the Classic panel style is selected.
///
/// Kept as 1.12 drew it (header, sliding capsule tab bar, footer). It sizes
/// itself with the same measured heights as `MainMenuView`: see the
/// measurement contract in MainMenuView.swift, which these views follow too.
struct ClassicMainMenuView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
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
            headerView
                .measureChromeHeight()

            if DoubleUsagePromo.isCampaignActive() {
                promoBannerView
                    .measureChromeHeight()
            }

            tabBar
                .measureChromeHeight()

            Group {
                switch panel.classicSelectedTab {
                case .usage:
                    ClassicUsageDashboardView()
                case .costs:
                    ClassicCostDetailView()
                case .accounts:
                    ClassicAccountSwitcherView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footerView
                .measureChromeHeight()
        }
        .frame(width: 360, height: popoverHeight)
        .animation(.easeInOut(duration: 0.2), value: popoverHeight)
        .background(.ultraThinMaterial)
        .onPreferenceChange(UsageContentHeightKey.self) { value in
            if value > 0 { panel.usageContentHeight = value }
        }
        .onPreferenceChange(ChromeHeightKey.self) { value in
            if value > 0 { panel.chromeHeight = value }
        }
        // Observe popoverHeight explicitly so SwiftUI tracks the computed value
        // as a dependency of the .frame above; some Release builds otherwise
        // locked the panel at its first height (1.5.3).
        .onChange(of: popoverHeight) { _, new in
            popoverLog.info("[classic height] popover=\(new)")
        }
    }

    // MARK: - Dynamic Popover Height

    /// See `PanelModel.popoverHeight`, which the hidden panel sizes itself by.
    private var popoverHeight: CGFloat { panel.popoverHeight }

    // MARK: - Promo Banner

    private var promoBannerView: some View {
        HStack {
            Image(systemName: "gift.fill")
                .foregroundStyle(Classic.brand)

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
        .background(Classic.subtleBrand)
    }

    private var localOffPeakTimeString: String {
        guard let etTimeZone = TimeZone(identifier: "America/New_York") else {
            return String(localized: "Double limits: 2 PM - 8 AM ET & Weekends", bundle: L10n.bundle)
        }

        let today = Date()
        var etCalendar = Calendar(identifier: .gregorian)
        etCalendar.timeZone = etTimeZone

        // Double usage runs from 2:00 PM ET to 8:00 AM ET the next day.
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
                .foregroundStyle(Classic.brand)

            VStack(alignment: .leading, spacing: 3) {
                if let account = appState.activeAccount {
                    HStack(spacing: 6) {
                        Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                            .font(.headline)
                        if let sub = account.displaySubscriptionType {
                            ClassicBadge(text: sub, color: Classic.brand)
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
            Capsule()
                .fill(.tabFill)
                .overlay(Capsule().stroke(.tabBorder, lineWidth: 1))

            // Sliding indicator
            GeometryReader { geo in
                let count = CGFloat(Tab.allCases.count)
                let tabWidth = geo.size.width / count
                let index = CGFloat(Tab.allCases.firstIndex(of: panel.classicSelectedTab) ?? 0)
                Capsule()
                    .fill(Classic.brand)
                    .padding(2)
                    .frame(width: tabWidth)
                    .offset(x: tabWidth * index)
                    .animation(.easeInOut(duration: 0.15), value: panel.classicSelectedTab)
            }

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
                    .foregroundStyle(panel.classicSelectedTab == tab ? .white : .textSecondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            panel.classicSelectedTab = tab
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
                NotificationCenter.default.post(name: .ccswitcherOpenSettings, object: nil)
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
