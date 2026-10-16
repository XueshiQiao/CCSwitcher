import SwiftUI

struct CountdownLabel: View {
    enum Purpose { case quotaReset, refresh }
    let deadline: Date?
    let now: Date
    let purpose: Purpose

    var body: some View {
        switch HourMinuteCountdown(until: deadline, now: now) {
        case .unknown:
            Text("Reset time unknown")
        case .elapsed:
            if purpose == .quotaReset {
                Text("Reset time reached · waiting for CLI data")
            } else {
                Text("Ready to refresh")
            }
        case .remaining(let hours, let minutes):
            if purpose == .quotaReset {
                if hours >= 24 {
                    Text("Resets in \(hours) hr \(minutes) min (\(hours / 24) days)")
                } else {
                    Text("Resets in \(hours) hr \(minutes) min")
                }
            } else {
                Text("Refresh available in \(hours) hr \(minutes) min")
            }
        }
    }
}
