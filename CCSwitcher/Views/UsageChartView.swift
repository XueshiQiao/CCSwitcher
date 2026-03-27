import SwiftUI

/// A simple bar chart showing daily message counts.
struct UsageChartView: View {
    let activities: [DailyActivity]

    var body: some View {
        if activities.isEmpty {
            ContentUnavailableView {
                Label("No Data", systemImage: "chart.bar")
            } description: {
                Text("Usage data will appear here")
            }
            .font(.caption)
        } else {
            GeometryReader { geo in
                let maxCount = activities.map(\.messageCount).max() ?? 1
                let barWidth = max(4, (geo.size.width - CGFloat(activities.count - 1) * 3) / CGFloat(activities.count))

                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(activities) { activity in
                        VStack(spacing: 4) {
                            // Bar
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(for: activity))
                                .frame(
                                    width: barWidth,
                                    height: max(2, CGFloat(activity.messageCount) / CGFloat(maxCount) * (geo.size.height - 24))
                                )

                            // Date label
                            Text(shortDate(activity.date))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: barWidth)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func barColor(for activity: DailyActivity) -> Color {
        let isToday = activity.date == todayString()
        return isToday ? .brand : .blue.opacity(0.7)
    }

    private func shortDate(_ dateStr: String) -> String {
        // "2026-03-21" -> "3/21"
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return dateStr
        }
        return "\(month)/\(day)"
    }

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
