import XCTest
import Foundation

final class SubscriptionPlanTests: XCTestCase {
    private let email = "a@example.com"
    private let org = "org-1"

    private func resolve(_ profile: [String: Any]?, credential: String? = "max", email: String? = "a@example.com", orgId: String? = "org-1") -> String? {
        SubscriptionPlan.resolve(email: email, orgId: orgId, subscriptionType: credential, profile: profile)
    }

    private func profile(_ organizationType: Any?, email: Any? = "a@example.com", org: Any? = "org-1") -> [String: Any] {
        var p: [String: Any] = [:]
        if let email { p["emailAddress"] = email }
        if let org { p["organizationUuid"] = org }
        if let organizationType { p["organizationType"] = organizationType }
        return p
    }

    func testKnownTypesOverrideTheCredential() {
        XCTAssertEqual(resolve(profile("claude_pro")), "pro")
        XCTAssertEqual(resolve(profile("claude_max")), "max")
        XCTAssertEqual(resolve(profile("claude_team")), "team")
        XCTAssertEqual(resolve(profile("claude_enterprise")), "enterprise")
    }

    func testUnknownOrMalformedTypesKeepTheCredential() {
        for value: Any in ["claude_free", "claude_ultra_2027", "", "CLAUDE_PRO", 42, 1.5, true, NSNull(), ["x": 1], [1, 2]] {
            XCTAssertEqual(resolve(profile(value)), "max", "organizationType = \(value)")
        }
        XCTAssertEqual(resolve(profile(nil)), "max")
        XCTAssertNil(resolve(profile("claude_free"), credential: nil))
    }

    func testAnotherAccountsProfileIsIgnored() {
        XCTAssertEqual(resolve(profile("claude_pro", email: "b@example.com")), "max")
        XCTAssertEqual(resolve(profile("claude_pro", email: nil)), "max")
        XCTAssertEqual(resolve(profile("claude_pro", email: 7)), "max")
        XCTAssertEqual(resolve(profile("claude_pro", org: "org-2")), "max")
    }

    func testMissingInputsKeepTheCredential() {
        XCTAssertEqual(resolve(nil), "max")
        XCTAssertEqual(resolve([:]), "max")
        XCTAssertEqual(resolve(profile("claude_pro"), email: nil), "max")
    }

    func testProfileWithoutAUsableOrgIsIgnoredWhenTheLoginHasOne() {
        for value: Any in [NSNull(), "", 7, ["org-1"], ["id": "org-1"]] {
            XCTAssertEqual(resolve(profile("claude_pro", org: value)), "max", "organizationUuid = \(value)")
        }
        XCTAssertEqual(resolve(profile("claude_pro", org: nil)), "max")
    }

    func testOrgCheckIsSkippedWhenTheLoginHasNoOrg() {
        XCTAssertEqual(resolve(profile("claude_pro"), orgId: nil), "pro")
        XCTAssertEqual(resolve(profile("claude_pro", org: nil), orgId: nil), "pro")
    }

    func testOddEmailValuesAreIgnored() {
        for value: Any in [NSNull(), "", true, ["a@example.com"], ["v": "a@example.com"], "A@example.com", "a@example.com\u{200B}"] {
            XCTAssertEqual(resolve(profile("claude_pro", email: value)), "max", "emailAddress = \(value)")
        }
    }

    func testOddStringTypesKeepTheCredential() {
        for value in ["claude_pro\u{200B}", " claude_pro", "claude_pro ", "claude_专业", "🙂", String(repeating: "x", count: 100_000)] {
            XCTAssertEqual(resolve(profile(value)), "max")
        }
    }
}
