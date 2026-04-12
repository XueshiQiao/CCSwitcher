import SwiftUI

/// The main popover content shown when clicking the menubar icon.
struct MainMenuView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var selectedTab: Tab = .usage

    enum Tab: String, CaseIterable {
        case usage, costs, accounts

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .usage: "Usage"
            case .costs: "Costs"
            case .accounts: "Accounts"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            if isPromoActive() {
                promoBannerView
            }

            // Tab selector
            tabBar

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
        }
        .frame(width: 360, height: 540)
        .background(.ultraThinMaterial)
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
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.subtleBrand)
    }
    
    private func isPromoActive() -> Bool {
        let date = Date()
        let calendar = Calendar(identifier: .gregorian)
        
        var promoStartComponents = DateComponents()
        promoStartComponents.year = 2026
        promoStartComponents.month = 3
        promoStartComponents.day = 13
        
        var promoEndComponents = DateComponents()
        promoEndComponents.year = 2026
        promoEndComponents.month = 3
        promoEndComponents.day = 29 // up to March 28 inclusive
        
        guard let start = calendar.date(from: promoStartComponents),
              let end = calendar.date(from: promoEndComponents) else {
            return false
        }
        
        return date >= start && date < end
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
                            Text(sub)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.brand, in: Capsule())
                        }
                    }
                    Text(account.displayEmail(obfuscated: !showFullEmail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("CCSwitcher")
                        .font(.headline)
                    Text("No account connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            // Background capsule — 15% white fill + 40% white stroke
            Capsule()
                .fill(Color.white.opacity(0.15))
                .overlay(Capsule().stroke(Color.white.opacity(0.40), lineWidth: 1))

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
                    Text(tab.localizedTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(selectedTab == tab ? .white : .secondary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        }
                }
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 12)
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
                    .foregroundStyle(.secondary)
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
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
