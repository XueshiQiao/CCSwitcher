import XCTest
import Foundation

final class AutoSwitchEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A usage window as the API returns it. `resetsIn` is seconds from `now`;
    /// nil leaves `resets_at` out.
    private func window(_ utilization: Double, resetsIn: TimeInterval? = 3600) -> [String: Any] {
        var w: [String: Any] = ["utilization": utilization]
        if let resetsIn {
            w["resets_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(resetsIn))
        }
        return w
    }

    private func usage(fiveHour: [String: Any]? = nil, sevenDay: [String: Any]? = nil) throws -> UsageAPIResponse {
        var body: [String: Any] = [:]
        if let fiveHour { body["five_hour"] = fiveHour }
        if let sevenDay { body["seven_day"] = sevenDay }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(UsageAPIResponse.self, from: data)
    }

    private func account(_ email: String, active: Bool = false) -> Account {
        Account(email: email, displayName: email, isActive: active)
    }

    private func rank(
        active: Account,
        candidates: [Account],
        usage: [UUID: UsageAPIResponse],
        switchable: Set<UUID>? = nil,
        activeSampledThisCycle: Bool = true,
        threshold: Double = 90,
        hysteresis: Double = 10
    ) -> [UUID] {
        AutoSwitchEngine.rankedTargets(
            active: active,
            candidates: candidates,
            usageByAccount: usage,
            isSwitchable: { switchable?.contains($0.id) ?? true },
            activeSampledThisCycle: activeSampledThisCycle,
            threshold: threshold,
            hysteresisPct: hysteresis,
            asOf: now
        ).map(\.id)
    }

    // MARK: - bindingUtilization

    func testNoUsageMeansNoReading() {
        XCTAssertNil(AutoSwitchEngine.bindingUtilization(nil, asOf: now))
    }

    func testBindingIsTheHigherWindow() throws {
        let u = try usage(fiveHour: window(40), sevenDay: window(75))
        XCTAssertEqual(AutoSwitchEngine.bindingUtilization(u, asOf: now), 75)
    }

    func testExpiredWindowIsIgnored() throws {
        let u = try usage(fiveHour: window(95, resetsIn: -60), sevenDay: window(30))
        XCTAssertEqual(AutoSwitchEngine.bindingUtilization(u, asOf: now), 30)
    }

    func testWindowWithoutResetIsKeptOnlyWhenLenient() throws {
        let u = try usage(fiveHour: window(80, resetsIn: nil))
        XCTAssertEqual(AutoSwitchEngine.bindingUtilization(u, asOf: now), 80)
        XCTAssertNil(AutoSwitchEngine.bindingUtilization(u, asOf: now, requireKnownWindow: true))
    }

    func testUnparseableResetCountsAsUnknown() throws {
        let u = try usage(fiveHour: ["utilization": 80, "resets_at": "soon"])
        XCTAssertEqual(AutoSwitchEngine.bindingUtilization(u, asOf: now), 80)
        XCTAssertNil(AutoSwitchEngine.bindingUtilization(u, asOf: now, requireKnownWindow: true))
    }

    // MARK: - rankedTargets

    func testStaysPutBelowThreshold() throws {
        let active = account("a@x.com", active: true)
        let other = account("b@x.com")
        let samples = [active.id: try usage(fiveHour: window(89)),
                     other.id: try usage(fiveHour: window(5))]
        XCTAssertEqual(rank(active: active, candidates: [other], usage: samples), [])
    }

    func testSwitchesAtExactlyTheThreshold() throws {
        let active = account("a@x.com", active: true)
        let other = account("b@x.com")
        let samples = [active.id: try usage(fiveHour: window(90)),
                     other.id: try usage(fiveHour: window(5))]
        XCTAssertEqual(rank(active: active, candidates: [other], usage: samples), [other.id])
    }

    func testStaysPutWhenActiveUsageIsUnknown() throws {
        let active = account("a@x.com", active: true)
        let other = account("b@x.com")
        let samples = [other.id: try usage(fiveHour: window(5))]
        XCTAssertEqual(rank(active: active, candidates: [other], usage: samples), [])
    }

    func testRanksByMostHeadroomAndAppliesHysteresis() throws {
        let active = account("a@x.com", active: true)
        let low = account("low@x.com")
        let mid = account("mid@x.com")
        let atCeiling = account("ceiling@x.com")
        let tooHigh = account("high@x.com")
        let samples = [
            active.id: try usage(fiveHour: window(95)),
            low.id: try usage(fiveHour: window(10)),
            mid.id: try usage(sevenDay: window(50)),
            atCeiling.id: try usage(fiveHour: window(80)),  // threshold 90 - hysteresis 10
            tooHigh.id: try usage(fiveHour: window(81)),
        ]
        XCTAssertEqual(rank(active: active, candidates: [tooHigh, atCeiling, mid, low], usage: samples),
                       [low.id, mid.id, atCeiling.id])
    }

    func testSkipsUnswitchableUnsampledAndActiveCandidates() throws {
        let active = account("a@x.com", active: true)
        let blocked = account("blocked@x.com")
        let unsampled = account("unsampled@x.com")
        let good = account("good@x.com")
        let samples = [
            active.id: try usage(fiveHour: window(99)),
            blocked.id: try usage(fiveHour: window(1)),
            good.id: try usage(fiveHour: window(20)),
        ]
        let ranked = rank(active: active,
                          candidates: [active, blocked, unsampled, good],
                          usage: samples,
                          switchable: [active.id, unsampled.id, good.id])
        XCTAssertEqual(ranked, [good.id])
    }

    func testRetainedActiveReadingNeedsAKnownReset() throws {
        let active = account("a@x.com", active: true)
        let other = account("b@x.com")
        let samples = [active.id: try usage(fiveHour: window(97, resetsIn: nil)),
                     other.id: try usage(fiveHour: window(5))]
        // Fetched this cycle: current by construction, so it may trigger.
        XCTAssertEqual(rank(active: active, candidates: [other], usage: samples, activeSampledThisCycle: true), [other.id])
        // Retained from an earlier cycle with no expiry: must not trigger.
        XCTAssertEqual(rank(active: active, candidates: [other], usage: samples, activeSampledThisCycle: false), [])
    }

    func testExpiredActiveReadingDoesNotTrigger() throws {
        let active = account("a@x.com", active: true)
        let other = account("b@x.com")
        let samples = [active.id: try usage(fiveHour: window(97, resetsIn: -1)),
                     other.id: try usage(fiveHour: window(5))]
        XCTAssertEqual(rank(active: active, candidates: [other], usage: samples, activeSampledThisCycle: false), [])
    }
}
