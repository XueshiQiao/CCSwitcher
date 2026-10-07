import SwiftUI

/// Hover tooltip that works inside MenuBarExtra panels (where `.help()` doesn't).
private struct StatWithTooltip<Content: View>: View {
    let tooltip: LocalizedStringKey
    @ViewBuilder let content: Content
    @State private var isHovering = false
    @Environment(\.locale) private var locale

    var body: some View {
        content
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(tooltip)
                    .font(.caption)
                    .padding(8)
                    .frame(width: 200)
                    .environment(\.locale, locale)
            }
    }
}

/// Local statistics aggregate all CLI sessions, independently of saved accounts.
struct LocalUsageSummaryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 10) {
            Text("All local sessions, not per-account usage.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            todayCostBanner
            todayActivityCard
        }
    }

    // MARK: - Today Cost Banner

    private var todayCostBanner: some View {
        let cost = appState.costSummary.todayCost
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text("Today's API-Equivalent Cost")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }

            StatWithTooltip(tooltip: Self.costDisclaimer) {
                Text(cost >= 1 ? String(format: "$%.2f", cost) : String(format: "$%.4f", cost))
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .cardStyle()
    }

    private static let costDisclaimer: LocalizedStringKey = "Estimated API-equivalent cost of your Claude Code usage, for reference only."

    // MARK: - Today Activity Card

    private var todayActivityCard: some View {
        let stats = appState.activityStats
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(.brand)
                Text("Today's Activity")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            // Top stats row
            HStack(spacing: 0) {
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(stats.conversationTurns)", label: "Turns",
                             tooltip: "Messages you sent to Claude Code today")
                activityStat(icon: "clock", value: stats.activeCodingTimeString, label: "Active",
                             tooltip: "Estimated total time Claude worked for you today. Parallel sessions stack. Idle gaps >10 min excluded. This is an approximation based on message timestamps, not exact.")
                activityStat(icon: "doc.text", value: "\(stats.linesWritten)", label: "Lines",
                             tooltip: "Estimated lines of code written by Claude via Edit/Write tools")
            }

            // Model usage row — same style as stats above
            HStack(spacing: 0) {
                modelStat(name: "Fable", count: stats.modelUsage["Fable"] ?? 0,
                          tooltip: "Claude Fable 5 — most powerful model, the new flagship tier")
                modelStat(name: "Opus", count: stats.modelUsage["Opus"] ?? 0,
                          tooltip: "Claude Opus 4 — most capable model, best for complex tasks")
                modelStat(name: "Sonnet", count: stats.modelUsage["Sonnet"] ?? 0,
                          tooltip: "Claude Sonnet 4 — balanced speed and capability")
                modelStat(name: "Haiku", count: stats.modelUsage["Haiku"] ?? 0,
                          tooltip: "Claude Haiku 4 — fastest model, best for simple tasks")
            }
        }
        .cardStyle()
    }

    private func activityStat(icon: String, value: String, label: LocalizedStringKey, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 3) {
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelStat(name: String, count: Int, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 3) {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(count > 0 ? .primary : .quaternary)
                HStack(spacing: 3) {
                    Circle()
                        .fill(modelColor(name))
                        .frame(width: 7, height: 7)
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(count > 0 ? .tertiary : .quaternary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelColor(_ name: String) -> Color {
        switch name {
        case "Fable": return .purple
        case "Opus": return .brand
        case "Sonnet": return .blue
        case "Haiku": return .green
        default: return .gray
        }
    }

}

/// Stored quota belongs to one account; syncing is only available for the current login.
struct AccountUsageView: View {
    let account: Account
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var menuBarConfig: MenuBarConfig

    private var canSync: Bool { account.id == appState.activeAccount?.id && account.recycledAt == nil }
    private var syncBusy: Bool {
        appState.isLoggingIn || appState.isSwitching || appState.isLoading
            || !appState.refreshingUsageAccountIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usage = appState.accountUsage[account.id] {
                usageBars(usage, now: Date())
                extraUsageRow(usage.extraUsage)
            }
            if let errorState = appState.accountUsageErrors[account.id] {
                Label(errorState.message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if appState.accountUsage[account.id] == nil {
                Text(LocalizedStringKey(canSync
                     ? "Use Claude Code normally, then sync its local quota cache."
                     : "No local quota record"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            quotaRefreshControl(account)
        }
    }

    private func quotaRefreshControl(_ account: Account) -> some View {
        let available = appState.cliUsageCheckAvailableAt(account)
        return HStack(spacing: 10) {
            sampleAgeLabel(account)
            Spacer(minLength: 4)
            if canSync {
                Toggle("Auto sync", isOn: Binding(
                    get: { appState.automaticUsageAccountIDs.contains(account.id.uuidString) },
                    set: { enabled in
                        if enabled {
                            appState.automaticUsageAccountIDs.insert(account.id.uuidString)
                            appState.refreshLocalUsage()
                        } else {
                            appState.automaticUsageAccountIDs.remove(account.id.uuidString)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption2)
                .fixedSize()
                .disabled(syncBusy)
                Button {
                    Task { await appState.refreshAccountUsage(account) }
                } label: {
                    Label("Read cache", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Sync local data")
                .disabled(syncBusy)
                Button {
                    appState.openCLIUsageSession(account)
                } label: {
                    Label("Check with CLI", systemImage: "terminal")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help(available.map {
                    Text("CLI in \(max(1, Int(ceil($0.timeIntervalSinceNow / 60)))) min")
                } ?? Text("Open the official CLI's /usage in safe mode. The CLI may connect to Anthropic. No model message is sent."))
                .disabled(syncBusy || available != nil)
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    /// Preserve the age of cached readings after unsuccessful refresh attempts.
    @ViewBuilder
    private func sampleAgeLabel(_ account: Account) -> some View {
        if let sampledAt = appState.accountUsageSampledAt[account.id] {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text(sampledAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            }
            .font(.caption2)
            .foregroundStyle(.textSecondary)
        }
    }

    @ViewBuilder
    private func usageBars(_ usage: UsageAPIResponse, now: Date) -> some View {
        if let window = usage.fiveHour {
            usageRow(label: "Session", window: window, kind: .session, now: now)
        }
        if let window = usage.sevenDay {
            usageRow(label: "Weekly", window: window, kind: .weekly, now: now)
        }
        if let window = usage.sevenDayFable {
            usageRow(label: "Weekly · Fable", window: window, kind: .weekly, now: now)
        } else {
            Text("Fable · Not collected yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let window = usage.sevenDayOpus {
            usageRow(label: "Weekly · Opus", window: window, kind: .weekly, now: now)
        }
        if let window = usage.sevenDaySonnet {
            usageRow(label: "Weekly · Sonnet", window: window, kind: .weekly, now: now)
        }
        if let window = usage.sevenDayOauthApps {
            usageRow(label: "Weekly · OAuth apps", window: window, kind: .weekly, now: now)
        }
        if let window = usage.sevenDayCowork {
            usageRow(label: "Weekly · Cowork", window: window, kind: .weekly, now: now)
        }
        if let window = usage.iguanaNecktie {
            usageRow(label: "Iguana necktie", window: window, kind: .weekly, now: now)
        }
    }

    @ViewBuilder
    private func extraUsageRow(_ extra: ExtraUsage?) -> some View {
        if extra?.isEnabled == true {
            Label("Extra usage", systemImage: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Usage Row

    private func usageRow(label: LocalizedStringKey, window: UsageWindow, kind: LimitBarKind, now: Date) -> some View {
        let fillColor = menuBarConfig.limitBarColor(for: kind, utilization: window.utilization, context: .dashboard)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                CountdownLabel(deadline: window.resetsAtDate, now: now, purpose: .quotaReset)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let utilization = window.utilization {
                    Text("Used \(Int(utilization))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(fillColor)
                } else {
                    Text("Usage unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let utilization = window.utilization {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.progressTrack)
                        Capsule().fill(fillColor)
                            .frame(width: max(0, geo.size.width * min(utilization / 100.0, 1.0)))
                    }
                }
                .frame(height: 5)
            }
        }
    }
}
