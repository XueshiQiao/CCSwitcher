import SwiftUI

/// Hover tooltip for stats. Uses the native `.help` tag: the popover lives in our
/// own key panel, where tooltips work (a nested SwiftUI popover would steal key
/// status and dismiss the panel).
private struct StatWithTooltip<Content: View>: View {
    let tooltip: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        content
            .contentShape(Rectangle())
            .help(tooltip)
    }
}

/// Shows real usage limits from Claude API, one card per account.
struct UsageDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var menuBarConfig: MenuBarConfig
    @AppStorage("showFullEmail") private var showFullEmail = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if appState.accounts.isEmpty && appState.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading usage data...")
                            .font(.caption)
                            .foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if appState.accounts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Theme.glow)
                            .frame(width: 64, height: 64)
                            .surface(radius: 32)
                        Text("Usage data unavailable")
                            .font(.subheadline)
                            .foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    // Today's cost (local parsing, no API needed)
                    todayCostBanner

                    // Today's activity stats
                    todayActivityCard

                    ForEach(appState.accounts) { account in
                        accountUsageCard(account: account, usage: appState.accountUsage[account.id])
                    }
                }
            }
            .padding(.horizontal, Theme.pad)
            .padding(.top, 6)
            .padding(.bottom, 12)
            // Report this VStack's intrinsic height to MainMenuView so it can
            // size the popover frame to fit the Usage tab's content exactly.
            // See MainMenuView.swift for the measurement contract.
            .measureUsageContentHeight()
        }
        .scrollIndicators(.never)
    }

    // MARK: - Today Cost Banner

    private var todayCostBanner: some View {
        let cost = appState.costSummary.todayCost
        return StatWithTooltip(tooltip: Self.costDisclaimer) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's API-Equivalent Cost")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                    Text(cost >= 1 ? String(format: "$%.2f", cost) : String(format: "$%.4f", cost))
                        .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: cost))
                        .animation(Theme.spring, value: cost)
                }
                Spacer(minLength: 0)
                Image(systemName: "dollarsign")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Theme.accentGradient)
                            .shadow(color: Theme.glow.opacity(0.4), radius: 10, y: 3)
                    )
            }
            .card(padding: 14)
        }
    }

    private static let costDisclaimer: LocalizedStringKey = "Estimated API-equivalent cost of your Claude Code usage, for reference only."

    // MARK: - Today Activity

    private var todayActivityCard: some View {
        let stats = appState.activityStats
        return VStack(spacing: 8) {
            SectionLabel(title: "Today's Activity")
                .padding(.top, 2)

            HStack(spacing: 8) {
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(stats.conversationTurns)", label: "Turns",
                             tooltip: "Messages you sent to Claude Code today")
                activityStat(icon: "clock", value: stats.activeCodingTimeString, label: "Active time",
                             tooltip: "Estimated total time Claude worked for you today. Parallel sessions stack. Idle gaps >10 min excluded. This is an approximation based on message timestamps, not exact.")
                activityStat(icon: "doc.text", value: "\(stats.linesWritten)", label: "Lines",
                             tooltip: "Estimated lines of code written by Claude via Edit/Write tools")
            }

            modelMix(stats.modelUsage)
        }
    }

    private func activityStat(icon: String, value: String, label: LocalizedStringKey, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.glow)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(Theme.spring, value: value)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .surface()
        }
    }

    private static let models: [(name: String, tooltip: LocalizedStringKey)] = [
        ("Fable", "Claude Fable 5 — most powerful model, the new flagship tier"),
        ("Opus", "Claude Opus 4 — most capable model, best for complex tasks"),
        ("Sonnet", "Claude Sonnet 4 — balanced speed and capability"),
        ("Haiku", "Claude Haiku 4 — fastest model, best for simple tasks"),
    ]

    /// Proportional bar of today's model mix with a legend underneath.
    private func modelMix(_ usage: [String: Int]) -> some View {
        let counts = Self.models.map { usage[$0.name] ?? 0 }
        let total = counts.reduce(0, +)
        let gaps = CGFloat(max(counts.filter { $0 > 0 }.count - 1, 0)) * 2

        return VStack(spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: total > 0 ? 2 : 0) {
                    if total > 0 {
                        ForEach(Array(Self.models.enumerated()), id: \.offset) { i, model in
                            if counts[i] > 0 {
                                Capsule()
                                    .fill(modelColor(model.name))
                                    .frame(width: max(4, (geo.size.width - gaps) * CGFloat(counts[i]) / CGFloat(total)))
                            }
                        }
                    } else {
                        Capsule().fill(Theme.well)
                    }
                }
            }
            .frame(height: 6)
            .animation(Theme.spring, value: counts)

            HStack(spacing: 0) {
                ForEach(Array(Self.models.enumerated()), id: \.offset) { i, model in
                    modelStat(name: model.name, count: counts[i], tooltip: model.tooltip)
                }
            }
        }
        .card(padding: 12)
    }

    private func modelStat(name: String, count: Int, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 3) {
                Text("\(count)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(count > 0 ? Theme.text : Theme.faint)
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(Theme.spring, value: count)
                HStack(spacing: 4) {
                    Circle()
                        .fill(modelColor(name))
                        .frame(width: 6, height: 6)
                        .opacity(count > 0 ? 1 : 0.4)
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(count > 0 ? Theme.dim : Theme.faint)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelColor(_ name: String) -> Color {
        switch name {
        case "Fable": return Color(hexRGB: "#A08BD0") ?? .purple
        case "Opus": return .brand
        case "Sonnet": return Color(hexRGB: "#6A9BCC") ?? .blue
        case "Haiku": return Color(hexRGB: "#8FAF6E") ?? .green
        default: return Theme.faint
        }
    }

    // MARK: - Per-Account Card

    private func accountUsageCard(account: Account, usage: UsageAPIResponse?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            accountHeader(account)
            if let usage = usage {
                usageBars(usage)
                extraUsageRow(usage.extraUsage)
                sampleAgeLabel(account)
            } else if let errorState = appState.accountUsageErrors[account.id] {
                HStack(spacing: 8) {
                    Image(systemName: errorState.isRateLimited ? "timer" : (errorState.isExpired ? "exclamationmark.triangle" : "xmark.circle"))
                        .foregroundStyle(errorState.isExpired ? Theme.warning : Theme.danger)
                    Text(errorState.message)
                        .font(.caption)
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                    Spacer()
                }
            } else {
                // No sample yet (accounts are polled round-robin) - this is a
                // waiting state, not an error. The old hardcoded "Token expired"
                // text here made healthy accounts look broken.
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(Theme.dim)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Waiting for usage data...")
                        .font(.caption)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                }
            }
        }
        .card(padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.accent.opacity(account.isActive ? 0.45 : 0), lineWidth: 1)
        )
    }

    /// Accounts are polled round-robin (active + one other per cycle), so a
    /// card's numbers can be several cycles old — say so instead of letting a
    /// stale percentage render exactly like a live one. Hidden while the sample
    /// is fresh (< 90s); the relative text then counts up by itself.
    @ViewBuilder
    private func sampleAgeLabel(_ account: Account) -> some View {
        if let sampledAt = appState.accountUsageSampledAt[account.id],
           Date().timeIntervalSince(sampledAt) >= 90 {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.caption2)
                Text("Updated \(Text(sampledAt, style: .relative)) ago")
                    .font(.caption2)
            }
            .foregroundStyle(Theme.dim)
        }
    }

    @ViewBuilder
    private func accountHeader(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Avatar(name: account.effectiveDisplayName(obfuscated: !showFullEmail),
                   icon: account.provider.iconName, active: account.isActive, size: 24)

            Text(account.displayEmail(obfuscated: !showFullEmail))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if account.isActive {
                Badge(text: String(localized: "Active", bundle: L10n.bundle), color: Theme.success)
            }

            Spacer()

            if let sub = account.displaySubscriptionType {
                Badge(text: sub, color: Theme.glow)
            }

            if !account.isActive {
                Button("Switch") { Task { await appState.switchTo(account) } }
                    .buttonStyle(PrimaryButtonStyle(height: 24))
                    .focusable(false)
            }
        }
    }

    @ViewBuilder
    private func usageBars(_ usage: UsageAPIResponse) -> some View {
        if let session = usage.fiveHour {
            usageRow(
                label: Text("Session"),
                resetText: session.resetTimeString,
                utilization: session.utilization ?? 0,
                elapsed: session.elapsedPercent(windowSeconds: RateLimitWindow.fiveHourSeconds),
                kind: .session
            )
        }
        if let weekly = usage.sevenDay {
            usageRow(
                label: Text("Weekly"),
                resetText: weekly.resetTimeString,
                utilization: weekly.utilization ?? 0,
                elapsed: weekly.elapsedPercent(windowSeconds: RateLimitWindow.sevenDaySeconds),
                kind: .weekly
            )
        }
        // The weekly limit scoped to one model. The server names the model, so
        // the label is verbatim rather than a localized key.
        if let scoped = usage.modelScopedWeekly {
            usageRow(
                label: Text(verbatim: scoped.modelName),
                resetText: scoped.window.resetTimeString,
                utilization: scoped.window.utilization ?? 0,
                elapsed: scoped.window.elapsedPercent(windowSeconds: RateLimitWindow.sevenDaySeconds),
                kind: .modelWeekly
            )
        }
    }

    @ViewBuilder
    private func extraUsageRow(_ extra: ExtraUsage?) -> some View {
        if let extra {
            let enabled = extra.isEnabled == true
            HStack(spacing: 6) {
                Image(systemName: enabled ? "bolt.fill" : "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(enabled ? Theme.warning : Theme.faint)
                Text("Extra usage")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(LocalizedStringKey(enabled ? "On" : "Off"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(enabled ? Theme.warning : Theme.faint)
            }
        }
    }

    // MARK: - Usage Row

    private func usageRow(label: Text, resetText: String?, utilization: Double, elapsed: Double?, kind: LimitBarKind) -> some View {
        let fillColor = menuBarConfig.limitBarColor(for: kind, utilization: utilization, context: .dashboard)

        return VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                label
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer()
                if let resetText {
                    Text("Resets in \(resetText)")
                        .font(.caption2)
                        .foregroundStyle(Theme.dim)
                }
                Text("\(Int(utilization))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(fillColor)
                    .contentTransition(.numericText(value: utilization))
                    .animation(Theme.spring, value: utilization)
                    .frame(minWidth: 36, alignment: .trailing)
            }

            GlowBar(fraction: utilization / 100, color: fillColor, marker: elapsed.map { $0 / 100 })
        }
    }
}
