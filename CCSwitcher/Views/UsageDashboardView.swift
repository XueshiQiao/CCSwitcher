import SwiftUI

/// Hover tooltip that works inside MenuBarExtra panels (where `.help()` doesn't).
private struct StatWithTooltip<Content: View>: View {
    let tooltip: String
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        content
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(tooltip)
                    .font(.caption)
                    .padding(8)
                    .frame(width: 200)
            }
    }
}

/// Shows real usage limits from Claude API, one card per account.
struct UsageDashboardView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if appState.accountUsage.isEmpty && appState.accountUsageErrors.isEmpty && appState.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading usage data...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if appState.accountUsage.isEmpty && appState.accountUsageErrors.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("Usage data unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    // Today's cost banner
                    todayCostBanner

                    // Today's activity stats
                    todayActivityCard

                    ForEach(sortedAccountsByUsage) { account in
                        accountUsageCard(account: account, usage: appState.accountUsage[account.id])
                    }
                }

                // Last updated
                if let lastRefresh = appState.lastUsageRefresh {
                    HStack {
                        Spacer()
                        Text("Updated \(lastRefresh, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Today Cost Banner

    private var todayCostBanner: some View {
        let cost = appState.costSummary.todayCost
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Today's API-Equivalent Cost")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }

            StatWithTooltip(tooltip: Self.costDisclaimer) {
                Text(cost >= 1 ? String(format: "$%.2f", cost) : String(format: "$%.4f", cost))
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(cardBackground(isActive: true))
        .padding(.horizontal, 16)
    }

    private static let costDisclaimer = "Estimated API-equivalent cost of your Claude Code usage, for reference only."

    // MARK: - Today Activity Card

    private var todayActivityCard: some View {
        let stats = appState.activityStats
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(.brand)
                Text("Today's Activity")
                    .font(.caption.weight(.medium))
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
                modelStat(name: "Opus", count: stats.modelUsage["Opus"] ?? 0,
                          tooltip: "Claude Opus 4 — most capable model, best for complex tasks")
                modelStat(name: "Sonnet", count: stats.modelUsage["Sonnet"] ?? 0,
                          tooltip: "Claude Sonnet 4 — balanced speed and capability")
                modelStat(name: "Haiku", count: stats.modelUsage["Haiku"] ?? 0,
                          tooltip: "Claude Haiku 4 — fastest model, best for simple tasks")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.cardFill)
                .strokeBorder(.cardBorderBrand, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func activityStat(icon: String, value: String, label: String, tooltip: String) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 2) {
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelStat(name: String, count: Int, tooltip: String) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(count > 0 ? .primary : .quaternary)
                HStack(spacing: 3) {
                    Circle()
                        .fill(modelColor(name))
                        .frame(width: 6, height: 6)
                    Text(name)
                        .font(.system(size: 9))
                        .foregroundStyle(count > 0 ? .tertiary : .quaternary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelColor(_ name: String) -> Color {
        switch name {
        case "Opus": return .brand
        case "Sonnet": return .blue
        case "Haiku": return .green
        default: return .gray
        }
    }

    /// Accounts sorted by usage (lowest utilization first = most remaining)
    private var sortedAccountsByUsage: [Account] {
        appState.accounts.sorted { a, b in
            let utilA = appState.accountUsage[a.id]?.fiveHour?.utilization
                ?? appState.cachedUsage[a.id]?.effectiveSessionUtilization()
                ?? 999
            let utilB = appState.accountUsage[b.id]?.fiveHour?.utilization
                ?? appState.cachedUsage[b.id]?.effectiveSessionUtilization()
                ?? 999
            return utilA < utilB
        }
    }

    // MARK: - Per-Account Card

    private func accountUsageCard(account: Account, usage: UsageAPIResponse?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            accountHeader(account)
            if let usage = usage {
                let errorState = appState.accountUsageErrors[account.id]
                let isRateLimited = errorState?.isRateLimited ?? false
                usageBars(usage, isRateLimited: isRateLimited)
                extraUsageRow(usage.extraUsage)
            } else if let errorState = appState.accountUsageErrors[account.id] {
                if errorState.isExpired {
                    expiredTokenBanner(account: account)
                } else {
                    errorBanner(errorState)
                }
                rateLimitedPlaceholderBars()
            } else {
                expiredTokenBanner(account: account)
                rateLimitedPlaceholderBars()
            }
        }
        .padding(8)
        .background(cardBackground(isActive: account.isActive))
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            if !account.isActive {
                Task { await appState.switchTo(account) }
            }
        }
        .help(!account.isActive ? "Click to switch to this account" : "Current account")
    }

    @ViewBuilder
    private func accountHeader(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.iconName)
                .font(.caption)
                .foregroundStyle(account.isActive ? .brand : .secondary)

            Text(account.email)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            if account.isActive {
                Text("Active")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.green, in: Capsule())
            }

            Spacer()

            if let sub = account.subscriptionType {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.brand)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.subtleBrand, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func usageBars(_ usage: UsageAPIResponse, isRateLimited: Bool = false) -> some View {
        if let session = usage.fiveHour {
            if isRateLimited {
                rateLimitedSessionRow(session)
            } else {
                usageRow(label: "Session", resetText: session.resetDateString, utilization: session.utilization ?? 0)
            }
        }
        if let weekly = usage.sevenDay {
            usageRow(label: "Weekly", resetText: weekly.resetDateString, utilization: weekly.utilization ?? 0)
        }
    }

    /// Banner for expired token with re-authenticate action
    private func expiredTokenBanner(account: Account) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text("Token expired.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await appState.reauthenticateAccount(account) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                    Text("Re-auth")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
    }

    /// Placeholder bars when rate limited with no cached data at all
    /// Inline error/status banner shown above placeholder bars
    private func errorBanner(_ errorState: AppState.UsageErrorState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: errorState.isRateLimited ? "timer" : (errorState.isExpired ? "exclamationmark.triangle" : "xmark.circle"))
                .font(.caption2)
                .foregroundStyle(errorState.isRateLimited ? .orange : (errorState.isExpired ? .yellow : .red))
            Text(errorState.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func rateLimitedPlaceholderBars() -> some View {
        VStack(spacing: 4) {
            // Session row - rate limited
            HStack {
                Text("Session")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.progressTrack)
                    .frame(height: 6)

                HStack(spacing: 2) {
                    Image(systemName: "timer")
                        .font(.system(size: 8))
                    Text("Limited")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.orange)
                .frame(width: 60, alignment: .trailing)
            }
            // Weekly row - unknown
            HStack {
                Text("Weekly")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.progressTrack)
                    .frame(height: 6)

                Text("--")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }

    /// Session row when rate limited: shows "Rate limited" instead of utilization percentage
    private func rateLimitedSessionRow(_ session: UsageWindow) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("Session")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetText = session.resetDateString {
                    Text("Resets in \(resetText)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.progressTrack)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.orange)
                            .frame(width: max(0, geo.size.width * min((session.utilization ?? 0) / 100.0, 1.0)), height: 6)
                    }
                }
                .frame(height: 6)

                HStack(spacing: 2) {
                    Image(systemName: "timer")
                        .font(.system(size: 8))
                    Text("Limited")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.orange)
                .frame(width: 60, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func extraUsageRow(_ extra: ExtraUsage?) -> some View {
        if let extra {
            let enabled = extra.isEnabled == true
            let iconColor: Color = enabled ? .orange : .gray
            let statusColor: Color = enabled ? .orange : .gray
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: enabled ? "bolt.fill" : "bolt.slash")
                        .font(.caption2)
                        .foregroundStyle(iconColor)
                    Text("Extra usage")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(enabled ? "On" : "Off")
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }

                if enabled, let limit = extra.monthlyLimit, limit > 0 {
                    let usedDollars = (extra.usedCredits ?? 0) / 100.0
                    let limitDollars = limit / 100.0
                    let util = extra.utilization ?? (usedDollars / limitDollars * 100)
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.progressTrack)
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.orange)
                                    .frame(width: max(0, geo.size.width * min(util / 100.0, 1.0)), height: 6)
                            }
                        }
                        .frame(height: 6)

                        Text(String(format: "$%.2f / $%.0f", usedDollars, limitDollars))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func cardBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isActive ? .cardFillStrong : .cardFillNeutral)
            .strokeBorder(isActive ? .cardBorderBrand : .cardBorderNeutral, lineWidth: isActive ? 1.5 : 1)
    }

    // MARK: - Usage Row

    private func usageRow(label: String, resetText: String?, utilization: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetText {
                    Text("Resets in \(resetText)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.progressTrack)
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(colorForUtilization(utilization))
                            .frame(width: max(0, geo.size.width * min(utilization / 100.0, 1.0)), height: 6)
                    }
                }
                .frame(height: 6)

                Text("\(Int(utilization))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(utilization))
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private func colorForUtilization(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 60 { return .orange }
        return .green
    }
}
