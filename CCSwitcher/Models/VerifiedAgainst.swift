import Foundation

/// Build-time stamp produced by `Tools/verify_cost.sh` on PASS, bundled
/// into the app at `CCSwitcher/Resources/verified-against.json`. The
/// Cost tab reads this to render the "Verified against ccusage X on Y"
/// reassurance line, so users can see what version of the reference
/// tool we last reconciled against.
///
/// File is regenerated whenever the dev runs the verify script before
/// tagging a release. If it's missing, the UI quietly omits the line.
struct VerifiedAgainst: Codable {
    let ccusageVersion: String
    let verifiedOn: String      // "yyyy-MM-dd"
    let windowDays: Int
    let totalDollars: Double

    static func load() -> VerifiedAgainst? {
        guard let url = Bundle.main.url(forResource: "verified-against", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(VerifiedAgainst.self, from: data)
        else { return nil }
        return parsed
    }
}
