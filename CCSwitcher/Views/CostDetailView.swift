import SwiftUI

/// Full cost breakdown tab with today's card and daily history.
struct CostDetailView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                todayCard
                periodSummaryCards
                dailyHistorySection
                pricingInfoSection
            }
            .padding(.horizontal, Theme.pad)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    // MARK: - Summary Cards

    private var todayCard: some View {
        let summary = appState.costSummary
        let today = summary.dailyCosts.first(where: { $0.date == todayString() })

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(todayDisplayDate())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.well))
            }

            Text(formatCost(summary.todayCost))
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: summary.todayCost))
                .animation(Theme.spring, value: summary.todayCost)

            if let today, !today.modelBreakdown.isEmpty {
                let total = max(today.totalCost, 0.000_001)
                VStack(spacing: 8) {
                    ForEach(today.modelBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { model, cost in
                        VStack(spacing: 4) {
                            HStack {
                                Text(model)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.dim)
                                Spacer()
                                Text(formatCost(cost))
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                            }
                            GlowBar(fraction: cost / total, color: Theme.glow, height: 5)
                        }
                    }
                }
                .padding(.top, 2)

                HStack {
                    Label("\(today.sessionCount) sessions", systemImage: "terminal")
                    Spacer()
                    Text("\(formatTokenCount(today.totalTokens)) tokens")
                }
                .font(.caption2)
                .foregroundStyle(Theme.dim)
                .padding(.top, 2)
            }
        }
        .card(padding: 14)
    }

    private var periodSummaryCards: some View {
        let costs = appState.costSummary.dailyCosts
        let todayStr = todayString()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let last7 = costForLastDays(7, costs: costs, today: todayStr, formatter: formatter)
        let last30 = costForLastDays(30, costs: costs, today: todayStr, formatter: formatter)

        return HStack(spacing: 8) {
            periodCard(title: "Last 7 Days", icon: "calendar", cost: last7)
            periodCard(title: "Last 30 Days", icon: "calendar.badge.clock", cost: last30)
        }
    }

    private func periodCard(title: LocalizedStringKey, icon: String, cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.glow)
            Spacer(minLength: 8)
            Text(formatCost(cost))
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText(value: cost))
                .animation(Theme.spring, value: cost)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.dim)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .surface()
    }

    private func costForLastDays(_ days: Int, costs: [DailyCost], today: String, formatter: DateFormatter) -> Double {
        guard let todayDate = formatter.date(from: today) else { return 0 }
        let startDate = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate)!
        let startStr = formatter.string(from: startDate)
        return costs.filter { $0.date >= startStr && $0.date <= today }.reduce(0) { $0 + $1.totalCost }
    }

    // MARK: - Daily History

    private var dailyHistorySection: some View {
        let costs = appState.costSummary.dailyCosts
        let maxCost = costs.map(\.totalCost).max() ?? 1

        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Daily History", trailing: String(localized: "Total: \(formatCost(appState.costSummary.totalCost))", bundle: L10n.bundle))
                .padding(.top, 4)

            if costs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.glow)
                    Text("No cost data available")
                        .font(.subheadline)
                        .foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .surface()
            } else {
                VStack(spacing: 2) {
                    ForEach(costs) { day in
                        dailyRow(day: day, maxCost: maxCost)
                    }
                }
                .padding(6)
                .surface()
            }
        }
    }

    private func dailyRow(day: DailyCost, maxCost: Double) -> some View {
        let isToday = day.date == todayString()
        let barRatio = maxCost > 0 ? day.totalCost / maxCost : 0

        return HStack(spacing: 8) {
            Text(shortDate(day.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isToday ? Theme.glow : Theme.dim)
                .frame(width: 36, alignment: .leading)

            Text(formatCost(day.totalCost))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(isToday ? Theme.glow : Theme.text)
                .frame(width: 56, alignment: .trailing)

            GlowBar(fraction: barRatio, color: isToday ? Theme.glow : Theme.glow.opacity(0.55), height: 6)

            // Compact model breakdown
            Text(day.modelBreakdown.keys.sorted().joined(separator: ", "))
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.dim)
                .frame(width: 50, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isToday ? Theme.accent.opacity(0.12) : .clear)
        )
    }

    // MARK: - Pricing Info

    private var pricingInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "How We Calculate")
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 10) {
                Text("Cost is computed from your local Claude Code session logs (jsonl files) under ~/.claude/projects/.")
                    .font(.caption2)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                if let v = VerifiedAgainst.load() {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.success)
                        Text("Verified against ccusage \(v.ccusageVersion) on \(v.verifiedOn) — \(v.windowDays)-day total matched to the cent.")
                            .font(.caption2)
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12)
        }
    }

    // MARK: - Helpers

    private func formatCost(_ cost: Double) -> String {
        Formatted.cost(cost, locale: L10n.locale)
    }

    /// "1.2M" / "1,2 M" / "120万" — the language's own short form.
    private func formatTokenCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(L10n.locale))
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func todayDisplayDate() -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: Date())
    }

    private func shortDate(_ dateStr: String) -> String {
        Formatted.shortDay(dateStr, locale: L10n.locale)
    }
}
