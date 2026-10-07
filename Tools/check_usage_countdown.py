#!/usr/bin/env python3
"""Offline check: countdowns stay in hours, round future minutes up, and distinguish missing/elapsed."""

from pathlib import Path
import subprocess
import tempfile


HARNESS = r'''
import Foundation

@main struct Check {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(HourMinuteCountdown(until: nil, now: now) == .unknown)
        precondition(HourMinuteCountdown(until: now, now: now) == .elapsed)
        precondition(HourMinuteCountdown(until: now.addingTimeInterval(-1), now: now) == .elapsed)
        precondition(HourMinuteCountdown(until: now.addingTimeInterval(1), now: now) == .remaining(hours: 0, minutes: 1))
        precondition(HourMinuteCountdown(until: now.addingTimeInterval(3600), now: now) == .remaining(hours: 1, minutes: 0))
        precondition(HourMinuteCountdown(until: now.addingTimeInterval(3601), now: now) == .remaining(hours: 1, minutes: 1))
        precondition(HourMinuteCountdown(until: now.addingTimeInterval(49 * 3600 + 7 * 60), now: now) == .remaining(hours: 49, minutes: 7))
        let valid = UsageWindow(utilization: 10, resetsAt: "2026-10-07T09:30:00.123Z")
        let plain = UsageWindow(utilization: 10, resetsAt: "2026-10-07T09:30:00Z")
        precondition(valid.resetsAtDate != nil && plain.resetsAtDate != nil)
        let invalid = UsageWindow(utilization: 10, resetsAt: "invalid-date")
        precondition(HourMinuteCountdown(until: invalid.resetsAtDate, now: now) == .unknown)
        print("PASS: cumulative hours, minute boundaries, elapsed/unknown, timestamp decoding")
    }
}
'''


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="ccswitcher-countdown-") as directory:
        temporary = Path(directory)
        harness = temporary / "check.swift"
        harness.write_text(HARNESS)
        executable = temporary / "check"
        subprocess.run([
            "swiftc", "-swift-version", "6", "-module-cache-path", str(temporary / "modules"),
            str(root / "CCSwitcher/Models/UsageData.swift"),
            str(root / "CCSwitcher/Views/Components/CountdownLabel.swift"),
            str(harness), "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
