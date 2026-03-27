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
                if appState.accountUsage.isEmpty && appState.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading usage data...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if appState.accountUsage.isEmpty {
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

                    ForEach(appState.accounts) { account in
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
                .fill(Color.brand.opacity(0.03))
                .strokeBorder(Color.brand.opacity(0.15), lineWidth: 1)
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

    // MARK: - Per-Account Card

    private func accountUsageCard(account: Account, usage: UsageAPIResponse?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            accountHeader(account)
            if let usage = usage {
                usageBars(usage)
                extraUsageRow(usage.extraUsage)
            } else if let errorState = appState.accountUsageErrors[account.id] {
                HStack {
                    Image(systemName: errorState.isRateLimited ? "timer" : (errorState.isExpired ? "exclamationmark.triangle" : "xmark.circle"))
                        .foregroundStyle(errorState.isExpired ? .yellow : .red)
                    Text(errorState.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.top, 4)
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("Token expired. Switch to this account in Claude Code to refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(cardBackground(isActive: account.isActive))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func accountHeader(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.iconName)
                .font(.caption)
                .foregroundStyle(account.isActive ? .brand : .secondary)

            Text(account.obfuscatedEmail)
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
                    .background(.brand.opacity(0.1), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func usageBars(_ usage: UsageAPIResponse) -> some View {
        if let session = usage.fiveHour {
            usageRow(label: "Session", resetText: session.resetTimeString, utilization: session.utilization ?? 0)
        }
        if let weekly = usage.sevenDay {
            usageRow(label: "Weekly", resetText: weekly.resetTimeString, utilization: weekly.utilization ?? 0)
        }
    }

    @ViewBuilder
    private func extraUsageRow(_ extra: ExtraUsage?) -> some View {
        if let extra {
            let enabled = extra.isEnabled == true
            let iconColor: Color = enabled ? .orange : .gray
            let statusColor: Color = enabled ? .orange : .gray
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
        }
    }

    private func cardBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isActive ? Color.brand.opacity(0.03) : Color.gray.opacity(0.03))
            .strokeBorder(isActive ? Color.brand.opacity(0.15) : Color.gray.opacity(0.12), lineWidth: 1)
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
                            .fill(Color.gray.opacity(0.15))
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
