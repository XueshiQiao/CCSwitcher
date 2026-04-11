import WidgetKit
import SwiftUI

// MARK: - Brand Color

private let brandColor = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)

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
                    extraUsageEnabled: true,
                    hasError: false,
                    errorMessage: nil
                )
            ],
            todayCost: 3.45,
            conversationTurns: 18,
            activeCodingTime: "1h 30m",
            linesWritten: 326,
            modelUsage: ["Opus": 12, "Sonnet": 5, "Haiku": 1],
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

private struct SmallWidgetView: View {
    let data: WidgetData

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(brandColor)
                Text("CCSwitcher")
                    .font(.caption.weight(.semibold))
                Spacer()
            }

            if let account = activeAccount {
                // Account info
                HStack(spacing: 4) {
                    Text(account.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                }

                Spacer(minLength: 2)

                // Usage bars
                if account.hasError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                        Text(account.errorMessage ?? "Error")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    compactUsageBar(label: "Session", utilization: account.sessionUtilization)
                    compactUsageBar(label: "Weekly", utilization: account.weeklyUtilization)
                }

                Spacer(minLength: 2)

                // Today's cost
                HStack {
                    Text(formatCost(data.todayCost))
                        .font(.title3.weight(.semibold).monospacedDigit())
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

    private func compactUsageBar(label: String, utilization: Double?) -> some View {
        let pct = utilization ?? 0
        return VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
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
                if let account = activeAccount {
                    Text(account.email)
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
                                Text(account.errorMessage ?? "Error")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            usageBar(label: "Session", utilization: account.sessionUtilization, resetTime: account.sessionResetTime)
                            Spacer(minLength: 4)
                            usageBar(label: "Weekly", utilization: account.weeklyUtilization, resetTime: account.weeklyResetTime)

                            if let extra = account.extraUsageEnabled {
                                Spacer(minLength: 4)
                                HStack(spacing: 4) {
                                    Image(systemName: extra ? "bolt.fill" : "bolt.slash")
                                        .font(.caption2)
                                        .foregroundStyle(extra ? .orange : .gray)
                                    Text("Extra usage")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(extra ? "On" : "Off")
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
                    statRow(icon: "bubble.left.and.bubble.right", label: "Turns", value: "\(data.conversationTurns)")
                    Spacer(minLength: 4)
                    statRow(icon: "clock", label: "Active", value: data.activeCodingTime)
                    Spacer(minLength: 4)
                    statRow(icon: "doc.text", label: "Lines", value: "\(data.linesWritten)")
                    Spacer(minLength: 4)
                    HStack(spacing: 5) {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(formatCost(data.todayCost))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.green)
                        Text("today")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func usageBar(label: String, utilization: Double?, resetTime: String?) -> some View {
        let pct = utilization ?? 0
        return VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset = resetTime {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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

    private func statRow(icon: String, label: String, value: String) -> some View {
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
        }
    }
}

// MARK: - Large Widget

private struct LargeWidgetView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.subheadline)
                    .foregroundStyle(brandColor)
                Text("CCSwitcher")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Today's activity + model usage
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    activityStat(icon: "bubble.left.and.bubble.right", value: "\(data.conversationTurns)", label: "Turns")
                    activityStat(icon: "clock", value: data.activeCodingTime, label: "Active")
                    activityStat(icon: "doc.text", value: "\(data.linesWritten)", label: "Lines")
                    activityStat(icon: "dollarsign.circle.fill", value: formatCost(data.todayCost), label: "Cost", valueColor: .green)
                }

                if !data.modelUsage.isEmpty {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 0.5)
                        .padding(.horizontal, 8)

                    HStack(spacing: 0) {
                        modelStat(name: "Opus", count: data.modelUsage["Opus"] ?? 0, color: brandColor)
                        modelStat(name: "Sonnet", count: data.modelUsage["Sonnet"] ?? 0, color: .blue)
                        modelStat(name: "Haiku", count: data.modelUsage["Haiku"] ?? 0, color: .green)
                    }
                }
            }
            .padding(.vertical, 10)
            .background(brandColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            // Per-account cards — expand to fill remaining space
            ForEach(Array(data.accounts.enumerated()), id: \.offset) { _, account in
                accountCard(account)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func activityStat(icon: String, value: String, label: String, valueColor: Color = .primary) -> some View {
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

    private func accountCard(_ account: WidgetAccountData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Account header
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.caption2)
                    .foregroundStyle(account.isActive ? brandColor : .secondary)
                Text(account.email)
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
                    Text(account.errorMessage ?? "Error")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                accountUsageBar(label: "Session", utilization: account.sessionUtilization, resetTime: account.sessionResetTime)
                accountUsageBar(label: "Weekly", utilization: account.weeklyUtilization, resetTime: account.weeklyResetTime)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(account.isActive ? brandColor.opacity(0.22) : Color.white.opacity(0.04))
                .strokeBorder(account.isActive ? brandColor.opacity(0.6) : Color.white.opacity(0.08), lineWidth: account.isActive ? 1.0 : 0.5)
        )
    }

    private func accountUsageBar(label: String, utilization: Double?, resetTime: String?) -> some View {
        let pct = utilization ?? 0
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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

// MARK: - Widget Bundle

@main
struct CCSwitcherWidgetBundle: WidgetBundle {
    var body: some Widget {
        CCSwitcherWidget()
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
