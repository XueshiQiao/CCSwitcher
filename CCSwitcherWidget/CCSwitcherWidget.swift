import WidgetKit
import SwiftUI

// MARK: - Brand Color

private let brandColor = Color(red: 0xE8 / 255.0, green: 0x6D / 255.0, blue: 0x45 / 255.0)

// MARK: - Timeline Entry

struct CCSwitcherEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?

    static let placeholder = CCSwitcherEntry(
        date: .now,
        data: WidgetData(
            accounts: [
                WidgetAccountData(
                    email: "us***@ex***.com",
                    displayName: "My Org",
                    subscriptionType: "Pro",
                    isActive: true,
                    sessionUtilization: 42,
                    sessionResetTime: "2 hr 15 min",
                    weeklyUtilization: 28,
                    weeklyResetTime: "in 3 days",
                    modelWeeklyLabel: "Fable",
                    modelWeeklyUtilization: 34,
                    modelWeeklyResetTime: "in 3 days",
                    extraUsageEnabled: true,
                    hasError: false,
                    errorMessage: nil
                )
            ],
            todayCost: 3.45,
            conversationTurns: 18,
            activeCodingTime: "1h 30m",
            linesWritten: 326,
            modelUsage: ["Fable": 18, "Opus": 12, "Sonnet": 5, "Haiku": 1],
            lastUpdated: .now
        )
    )
}

// MARK: - Timeline Provider

struct CCSwitcherProvider: TimelineProvider {
    func placeholder(in context: Context) -> CCSwitcherEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CCSwitcherEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CCSwitcherEntry>) -> Void) {
        let entry = currentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func currentEntry() -> CCSwitcherEntry {
        CCSwitcherEntry(date: .now, data: WidgetData.load())
    }
}

// MARK: - Widget Entry View

struct CCSwitcherWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: CCSwitcherEntry

    var body: some View {
        if let data = entry.data {
            switch family {
            case .systemSmall:
                SmallWidgetView(data: data)
            case .systemMedium:
                MediumWidgetView(data: data)
            case .systemLarge:
                LargeWidgetView(data: data)
            default:
                SmallWidgetView(data: data)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(brandColor)
                .widgetAccentable()
            Text("Open CCSwitcher")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("to load data")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Small Widget

/// Vertical density for the small widget.
///
/// A model-scoped weekly bar (e.g. "Fable") adds a third row to a layout that
/// was already close to the 155pt edge, so the whole layout is offered at
/// several densities and `ViewThatFits` picks the roomiest one that still fits.
/// Accounts without a scoped limit keep the original `.roomy` look.
private struct BarDensity {
    let stackSpacing: CGFloat
    let barSpacing: CGFloat
    let barHeight: CGFloat
    let costFont: Font

    static let roomy = BarDensity(stackSpacing: 6, barSpacing: 3, barHeight: 5, costFont: .title3)
    static let tight = BarDensity(stackSpacing: 4, barSpacing: 2, barHeight: 4, costFont: .callout)
    static let tightest = BarDensity(stackSpacing: 2, barSpacing: 2, barHeight: 4, costFont: .subheadline)
}

private struct SmallWidgetView: View {
    let data: WidgetData

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content(.roomy)
            content(.tight)
            content(.tightest)
        }
    }

    private func content(_ density: BarDensity) -> some View {
        VStack(alignment: .leading, spacing: density.stackSpacing) {
            header

            if let account = activeAccount {
                Spacer(minLength: 2)

                // Usage bars
                if account.hasError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                        if let msg = account.errorMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text("Error")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    compactUsageBar(label: Text("Session"), utilization: account.sessionUtilization, density: density)
                    compactUsageBar(label: Text("Weekly"), utilization: account.weeklyUtilization, density: density)
                    if let model = account.modelWeeklyLabel {
                        compactUsageBar(label: Text(verbatim: model), utilization: account.modelWeeklyUtilization, density: density)
                    }
                }

                Spacer(minLength: 2)

                // Today's cost
                HStack {
                    Text(formatCost(data.todayCost))
                        .font(density.costFont.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                    Text("today")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                Spacer()
                Text("No accounts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // Header — icon + account + badge
    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "brain.head.profile")
                .font(.caption)
                .foregroundStyle(brandColor)
                .widgetAccentable()
            if let account = activeAccount {
                Text(account.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let sub = account.subscriptionType {
                    Text(sub)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(brandColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(brandColor.opacity(0.15), in: Capsule())
                }
            } else {
                Text("CCSwitcher")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
        }
    }

    private func compactUsageBar(label: Text, utilization: Double?, density: BarDensity) -> some View {
        let pct = utilization ?? 0
        return VStack(spacing: density.barSpacing) {
            HStack {
                label
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(pct))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.quaternary)
                        .frame(height: density.barHeight)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(colorForUtilization(pct))
                        .frame(width: max(0, geo.size.width * min(pct / 100.0, 1.0)), height: density.barHeight)
                }
            }
            .frame(height: density.barHeight)
        }
    }
}

// MARK: - Medium Widget

private struct MediumWidgetView: View {
    let data: WidgetData

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(brandColor)
                    .widgetAccentable()
                if let account = activeAccount {
                    Text(account.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let sub = account.subscriptionType {
                        Text(sub)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(brandColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(brandColor.opacity(0.15), in: Capsule())
                    }
                }
                Spacer()
                Text(data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            // Main content: usage bars on left, activity on right
            HStack(spacing: 12) {
                // Left: Usage bars
                VStack(alignment: .leading, spacing: 0) {
                    if let account = activeAccount {
                        if account.hasError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                if let msg = account.errorMessage {
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                } else {
                                    Text("Error")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            usageBar(label: Text("Session"), utilization: account.sessionUtilization, resetTime: account.sessionResetTime)
                            Spacer(minLength: 4)
                            usageBar(label: Text("Weekly"), utilization: account.weeklyUtilization, resetTime: account.weeklyResetTime)

                            if let model = account.modelWeeklyLabel {
                                Spacer(minLength: 4)
                                usageBar(label: Text(verbatim: model), utilization: account.modelWeeklyUtilization, resetTime: account.modelWeeklyResetTime)
                            }

                            if let extra = account.extraUsageEnabled {
                                Spacer(minLength: 4)
                                HStack(spacing: 4) {
                                    Image(systemName: extra ? "bolt.fill" : "bolt.slash")
                                        .font(.caption2)
                                        .foregroundStyle(extra ? .orange : .gray)
                                    Text("Extra usage")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(LocalizedStringKey(extra ? "On" : "Off"))
                                        .font(.caption2)
                                        .foregroundStyle(extra ? .orange : .gray)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Divider
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)

                // Right: Activity stats
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    statRow(icon: "dollarsign.circle", label: "Cost", value: formatCost(data.todayCost), valueColor: .green)
                    Spacer(minLength: 4)
                    statRow(icon: "bubble.left.and.bubble.right", label: "Turns", value: "\(data.conversationTurns)")
                    Spacer(minLength: 4)
                    statRow(icon: "clock", label: "Active", value: data.activeCodingTime)
                    Spacer(minLength: 4)
                    statRow(icon: "doc.text", label: "Lines", value: "\(data.linesWritten)")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func usageBar(label: Text, utilization: Double?, resetTime: String?) -> some View {
        let pct = utilization ?? 0
        return VStack(spacing: 3) {
            HStack {
                label
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let reset = resetTime {
                    // Absolute reset times ("Wed 8:00 PM") wrap to two lines
                    // otherwise, and with three bars stacked there is no room
                    // for that.
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text("\(Int(pct))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.quaternary)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(colorForUtilization(pct))
                        .frame(width: max(0, geo.size.width * min(pct / 100.0, 1.0)), height: 5)
                }
            }
            .frame(height: 5)
        }
    }

    private func statRow(icon: String, label: LocalizedStringKey, value: String, valueColor: Color = .primary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(valueColor)
        }
    }
}

// MARK: - Large Widget

/// Vertical density for the large widget.
///
/// A model-scoped weekly bar (e.g. "Fable") adds a row to *every* account card,
/// which the stock spacing cannot absorb past a single account. Rather than
/// clipping the last card, the whole layout is offered at several densities and
/// `ViewThatFits` picks the roomiest that still fits — which also stops the
/// three-account case from spilling over the way it used to.
private struct LargeDensity {
    let bodySpacing: CGFloat
    let statsSpacing: CGFloat
    let statsPadding: CGFloat
    let cardSpacing: CGFloat
    let cardPadding: CGFloat

    static let roomy = LargeDensity(bodySpacing: 8, statsSpacing: 6, statsPadding: 10, cardSpacing: 10, cardPadding: 12)
    static let tight = LargeDensity(bodySpacing: 6, statsSpacing: 5, statsPadding: 7, cardSpacing: 7, cardPadding: 9)
    static let tightest = LargeDensity(bodySpacing: 4, statsSpacing: 3, statsPadding: 4, cardSpacing: 4, cardPadding: 5)
}

private struct LargeWidgetView: View {
    let data: WidgetData

    var body: some View {
        ViewThatFits(in: .vertical) {
            content(.roomy)
            content(.tight)
            content(.tightest)
        }
    }

    private func content(_ density: LargeDensity) -> some View {
        VStack(alignment: .leading, spacing: density.bodySpacing) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.subheadline)
                    .foregroundStyle(brandColor)
                    .widgetAccentable()
                Text("CCSwitcher")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Today's activity + model usage
            VStack(spacing: density.statsSpacing) {
                HStack(spacing: 0) {
                    activityStat(icon: "bubble.left.and.bubble.right", value: "\(data.conversationTurns)", label: "Turns")
                    activityStat(icon: "clock", value: data.activeCodingTime, label: "Active")
                    activityStat(icon: "doc.text", value: "\(data.linesWritten)", label: "Lines")
                    activityStat(icon: "dollarsign.circle", value: formatCost(data.todayCost), label: "Cost", valueColor: .green)
                }

                if !data.modelUsage.isEmpty {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 0.5)
                        .padding(.horizontal, 8)

                    HStack(spacing: 0) {
                        modelStat(name: "Fable", count: data.modelUsage["Fable"] ?? 0, color: .purple)
                        modelStat(name: "Opus", count: data.modelUsage["Opus"] ?? 0, color: brandColor)
                        modelStat(name: "Sonnet", count: data.modelUsage["Sonnet"] ?? 0, color: .blue)
                        modelStat(name: "Haiku", count: data.modelUsage["Haiku"] ?? 0, color: .green)
                    }
                }
            }
            .padding(.vertical, density.statsPadding)
            .background(brandColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            // Per-account cards — expand to fill remaining space
            ForEach(Array(data.accounts.enumerated()), id: \.offset) { _, account in
                accountCard(account, spacing: density.cardSpacing, padding: density.cardPadding)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func activityStat(icon: String, value: String, label: LocalizedStringKey, valueColor: Color = .primary) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(valueColor)
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func modelStat(name: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(count > 0 ? .primary : .quaternary)
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(count > 0 ? .tertiary : .quaternary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func accountCard(_ account: WidgetAccountData, spacing: CGFloat, padding: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Account header
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.caption2)
                    .foregroundStyle(account.isActive ? brandColor : .secondary)
                Text(account.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if account.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule()
                                .stroke(Color.green, lineWidth: 1)
                        )
                }
                Spacer()
                if let sub = account.subscriptionType {
                    Text(sub)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(brandColor)
                }
            }

            if account.hasError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    if let msg = account.errorMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Error")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                accountUsageBar(label: Text("Session"), utilization: account.sessionUtilization, resetTime: account.sessionResetTime)
                accountUsageBar(label: Text("Weekly"), utilization: account.weeklyUtilization, resetTime: account.weeklyResetTime)
                if let model = account.modelWeeklyLabel {
                    accountUsageBar(label: Text(verbatim: model), utilization: account.modelWeeklyUtilization, resetTime: account.modelWeeklyResetTime)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, padding)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(account.isActive ? brandColor.opacity(0.22) : Color.white.opacity(0.04))
                .strokeBorder(account.isActive ? brandColor.opacity(0.6) : Color.white.opacity(0.08), lineWidth: account.isActive ? 1.0 : 0.5)
        )
    }

    private func accountUsageBar(label: Text, utilization: Double?, resetTime: String?) -> some View {
        let pct = utilization ?? 0
        return HStack(spacing: 6) {
            label
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.quaternary)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(colorForUtilization(pct))
                        .frame(width: max(0, geo.size.width * min(pct / 100.0, 1.0)), height: 5)
                }
            }
            .frame(height: 5)
            Text("\(Int(pct))%")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(colorForUtilization(pct))
                .frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Circular (Rings) Widget

private struct CircleWidgetView: View {
    let data: WidgetData

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(spacing: 8) {
            // Header — show account name instead of app name
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(brandColor)
                    .widgetAccentable()
                Text(activeAccount?.displayName ?? "CCSwitcher")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let sub = activeAccount?.subscriptionType {
                    Text(sub)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(brandColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(brandColor.opacity(0.15), in: Capsule())
                }
            }

            Spacer(minLength: 0)

            if let account = activeAccount, !account.hasError {
                // A third ring has to share the same 155pt tile, so both the
                // gap and the stroke get thinner rather than the rings.
                let model = account.modelWeeklyLabel
                let lineWidth: CGFloat = model == nil ? 6 : 5
                HStack(spacing: model == nil ? 12 : 8) {
                    ringStat(
                        label: Text("Session"),
                        resetTime: account.sessionResetTime,
                        utilization: account.sessionUtilization,
                        accent: colorForUtilization(account.sessionUtilization ?? 0),
                        lineWidth: lineWidth
                    )
                    ringStat(
                        label: Text("Weekly"),
                        resetTime: account.weeklyResetTime,
                        utilization: account.weeklyUtilization,
                        accent: colorForUtilization(account.weeklyUtilization ?? 0),
                        lineWidth: lineWidth
                    )
                    if let model {
                        ringStat(
                            label: Text(verbatim: model),
                            resetTime: account.modelWeeklyResetTime,
                            utilization: account.modelWeeklyUtilization,
                            accent: colorForUtilization(account.modelWeeklyUtilization ?? 0),
                            lineWidth: lineWidth
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            } else if let account = activeAccount, account.hasError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                    if let msg = account.errorMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    } else {
                        Text("Error")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
            } else {
                Text("No accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func ringStat(label: Text, resetTime: String?, utilization: Double?, accent: Color, lineWidth: CGFloat) -> some View {
        let pct = utilization ?? 0
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(pct / 100.0, 1.0))
                    .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(pct))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .aspectRatio(1, contentMode: .fit)

            label
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let reset = resetTime {
                // Three rings leave ~35pt per column; shrink the countdown
                // rather than ellipsizing it down to "Wed…".
                Text(reset)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CircleWidgetEntryView: View {
    var entry: CCSwitcherEntry

    var body: some View {
        if let data = entry.data {
            CircleWidgetView(data: data)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 28))
                    .foregroundStyle(brandColor)
                Text("Open CCSwitcher")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("to load data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Helpers

private func colorForUtilization(_ pct: Double) -> Color {
    if pct >= 90 { return .red }
    if pct >= 60 { return .orange }
    return .green
}

private func formatCost(_ cost: Double) -> String {
    cost >= 1 ? String(format: "$%.2f", cost) : String(format: "$%.4f", cost)
}

// MARK: - Widget Definition

struct CCSwitcherWidget: Widget {
    let kind: String = "CCSwitcherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CCSwitcherProvider()) { entry in
            CCSwitcherWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("CCSwitcher")
        .description("Monitor your Claude Code account usage, costs, and activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CCSwitcherCircleWidget: Widget {
    let kind: String = "CCSwitcherCircleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CCSwitcherProvider()) { entry in
            CircleWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("CCSwitcher Rings")
        .description("Session and weekly usage shown as circular progress rings.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Widget Bundle

@main
struct CCSwitcherWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        CCSwitcherWidget()
        CCSwitcherCircleWidget()
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}

#Preview("Large", as: .systemLarge) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}
