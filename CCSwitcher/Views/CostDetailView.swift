import SwiftUI

/// API-equivalent estimates from all local CLI logs, independent of saved accounts.
struct CostDetailView: View {
    @EnvironmentObject private var appState: AppState
    @State private var period: Period = .week
    @State private var expandedDays: Set<String> = []

    private enum Period: Int, CaseIterable {
        case today = 1, week = 7, month = 30

        var title: LocalizedStringKey {
            switch self {
            case .today: "Today"
            case .week: "Last 7 Days"
            case .month: "Last 30 Days"
            }
        }
    }

    var body: some View {
        let summary = appState.costSummary.period(days: period.rawValue)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("Local logs · API-equivalent estimate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("All accounts on this Mac · API-equivalent estimate, not subscription charges or quota.")

                if summary.dailyCosts.isEmpty {
                    ContentUnavailableView("No cost data available", systemImage: "dollarsign.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    overview(summary)
                    ForEach(summary.dailyCosts.sorted { $0.date > $1.date }) { day in
                        dayCard(day)
                    }
                }
            }
            .padding(12)
        }
    }

    private func overview(_ summary: CostPeriodSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Priced subtotal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    costLabel(summary.knownCost, models: summary.models)
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overall cache hit rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    cacheRate(summary.cacheHitRate)
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Cache hit rate = cache read / (input + cache write + cache read). Output is excluded.")
            }
            if summary.hasUnpricedUsage {
                Text("Unpriced usage excluded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle(hasShadow: false)
    }

    private func dayCard(_ day: DailyCost) -> some View {
        let expanded = expandedDays.contains(day.date)
        let summary = CostPeriodSummary(models: day.models, dailyCosts: [day])
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if expanded { expandedDays.remove(day.date) }
                else { expandedDays.insert(day.date) }
            } label: {
                VStack(spacing: 5) {
                    HStack {
                        Text(day.date)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Spacer()
                        costLabel(day.totalCost, models: day.models)
                            .font(.caption.monospacedDigit())
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Cache hit rate")
                        cacheRate(summary.cacheHitRate).monospacedDigit()
                        Spacer()
                        if summary.hasUnpricedUsage && day.models.contains(where: { $0.cost != nil }) {
                            Text("Unpriced usage excluded")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(day.date))
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))

            if expanded {
                ForEach(day.models) { model in
                    Divider()
                    modelDetails(model)
                }
            }
        }
        .cardStyle(hasShadow: false)
    }

    private func modelDetails(_ model: ModelCost) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.modelID)
                .font(.system(size: 12, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let cost = model.cost {
                    Text(formatCost(cost)).monospacedDigit()
                } else {
                    Text("Unpriced").foregroundStyle(.secondary)
                }
                Spacer()
                Text("Cache hit rate").foregroundStyle(.secondary)
                cacheRate(model.cacheHitRate).monospacedDigit()
            }
            .font(.caption)
            VStack(spacing: 4) {
                tokenRow("Input", count: model.inputTokens)
                tokenRow("Output", count: model.outputTokens)
                tokenRow("Cache write", count: model.cacheWriteTokens)
                tokenRow("Cache read", count: model.cacheReadTokens)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func tokenRow(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count, format: .number).monospacedDigit()
        }
    }

    @ViewBuilder
    private func costLabel(_ cost: Double, models: [ModelCost]) -> some View {
        if cost > 0 || models.contains(where: { $0.cost != nil }) {
            Text(formatCost(cost))
        } else {
            Text("Unpriced")
        }
    }

    @ViewBuilder
    private func cacheRate(_ rate: Double?) -> some View {
        if let rate {
            Text(rate / 100, format: .percent.precision(.fractionLength(1)))
        } else {
            Text("Not applicable")
        }
    }

    private func formatCost(_ cost: Double) -> String {
        String(format: cost >= 1 ? "$%.2f" : "$%.4f", cost)
    }
}
