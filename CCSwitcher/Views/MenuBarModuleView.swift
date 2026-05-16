import SwiftUI

/// Renders one configured menu-bar module in the iStats-style two-line layout:
/// a short uppercase label on top and either a horizontal bar (for utilization
/// percentages) or a value text (for absolute numbers / times) on the bottom.
struct MenuBarModuleView: View {
    let module: MenuBarModule
    let appState: AppState
    let showFullEmail: Bool
    /// Tick value that recomputes reset countdowns once a minute.
    /// Passed in (and ignored by non-countdown modules) so the parent timer
    /// can drive view updates without each module owning a timer.
    let tick: Date

    // Fixed row geometry so every module shares the same baseline grid: the
    // label row and the value/bar row line up across all modules regardless of
    // whether the bottom row is text (taller) or a bar (shorter).
    private let labelRowHeight: CGFloat = 9
    private let valueRowHeight: CGFloat = 13

    var body: some View {
        if module == .account {
            // Account is shown as a single line (no label) — the name is
            // self-identifying and the `@` label added noise. No height frame:
            // wrapping the Text in a fixed-height frame truncated it.
            Text(accountText)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .fixedSize()
        } else {
            VStack(alignment: .center, spacing: 0) {
                Text(module.compactLabel)
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.2)
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .frame(height: labelRowHeight)

                valueRow
                    .frame(height: valueRowHeight)
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var valueRow: some View {
        switch module {
        case .account:
            Text(accountText)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .fixedSize()

        case .sessionBar:
            UtilizationBar(utilization: sessionUtilization)

        case .weeklyBar:
            UtilizationBar(utilization: weeklyUtilization)

        case .dailyCost:
            Text(dailyCostText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()

        case .sessionReset:
            Text(sessionResetText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()

        case .weeklyReset:
            Text(weeklyResetText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }

    // MARK: - Data accessors

    private var accountText: String {
        guard let account = appState.activeAccount else { return "—" }
        let name = account.effectiveDisplayName(obfuscated: !showFullEmail)
        return name.isEmpty ? "—" : name
    }

    private var sessionUtilization: Double? {
        guard let id = appState.activeAccount?.id else { return nil }
        return appState.accountUsage[id]?.fiveHour?.utilization
    }

    private var weeklyUtilization: Double? {
        guard let id = appState.activeAccount?.id else { return nil }
        return appState.accountUsage[id]?.sevenDay?.utilization
    }

    private var dailyCostText: String {
        let cost = appState.costSummary.todayCost
        guard cost > 0 else { return "—" }
        return String(format: "$%.2f", cost)
    }

    private var sessionResetText: String {
        // `tick` is read so SwiftUI recomputes on each timer fire.
        _ = tick
        guard let id = appState.activeAccount?.id,
              let s = appState.accountUsage[id]?.fiveHour?.compactResetString else {
            return "—"
        }
        return s
    }

    private var weeklyResetText: String {
        _ = tick
        guard let id = appState.activeAccount?.id,
              let s = appState.accountUsage[id]?.sevenDay?.compactResetString else {
            return "—"
        }
        return s
    }
}

/// Hollow rounded capsule with an inner filled pill whose width reflects
/// `utilization`. The API reports utilization as a 0–100 percentage (matching
/// `UsageDashboardView`), so we normalize to 0–1 here. Fill is monochrome
/// (adapts to the light/dark menu bar), turning red once utilization exceeds
/// 90% (and staying red on overage, clamped at 100%).
private struct UtilizationBar: View {
    /// 0–100 percentage (as returned by the usage API), or nil if unavailable.
    let utilization: Double?

    private let trackWidth: CGFloat = 26
    private let trackHeight: CGFloat = 8
    private let strokeWidth: CGFloat = 1
    private let innerInset: CGFloat = 1.5

    private var clamped: Double { min(max((utilization ?? 0) / 100.0, 0), 1) }

    private var fillColor: Color {
        guard let u = utilization, u > 90 else { return .primary }
        return .red
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Track — hollow capsule outline.
            Capsule()
                .stroke(
                    Color.primary.opacity(utilization == nil ? 0.25 : 0.55),
                    style: StrokeStyle(
                        lineWidth: strokeWidth,
                        dash: utilization == nil ? [2, 2] : []
                    )
                )
                .frame(width: trackWidth, height: trackHeight)

            // Fill — inset pill scaled to utilization. Omitted entirely when
            // no data so a missing value is visually distinct from 0%.
            if utilization != nil {
                Capsule()
                    .fill(fillColor)
                    .frame(
                        width: max(
                            0,
                            (trackWidth - innerInset * 2) * clamped
                        ),
                        height: trackHeight - innerInset * 2
                    )
                    .padding(.leading, innerInset)
            }
        }
        .frame(width: trackWidth, height: trackHeight)
    }
}
