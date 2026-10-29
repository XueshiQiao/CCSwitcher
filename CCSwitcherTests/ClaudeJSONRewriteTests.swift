import XCTest
import Foundation

/// Switching accounts rewrites `~/.claude.json`, a file the Claude CLI owns
/// and keeps most of its settings in. Only `oauthAccount` may change.
final class ClaudeJSONRewriteTests: XCTestCase {
    private let original = """
    {
      "numStartups": 412,
      "hasCompletedOnboarding": true,
      "autoUpdates": false,
      "tipsHistory": {"memory-command": 3, "theme-command": 0},
      "projects": {
        "/Users/me/code/app": {
          "allowedTools": [],
          "history": [{"display": "fix the tests", "pastedContents": {}}],
          "lastCost": 0.4217,
          "lastSessionId": null
        }
      },
      "oauthAccount": {
        "accountUuid": "11111111-1111-1111-1111-111111111111",
        "emailAddress": "old@example.com",
        "organizationName": "Old Org"
      }
    }
    """

    private let replacement: [String: AnyCodable] = [
        "accountUuid": AnyCodable("22222222-2222-2222-2222-222222222222"),
        "emailAddress": AnyCodable("new@example.com"),
        "organizationName": AnyCodable("New Org"),
        "hasExtraUsageEnabled": AnyCodable(false),
    ]

    private func rewrite(_ json: String) throws -> [String: Any] {
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
        let data = try KeychainService.claudeJSON(decoded, replacingOAuthAccount: replacement)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func parse(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testReplacesTheOAuthAccountBlock() throws {
        let result = try rewrite(original)
        let account = try XCTUnwrap(result["oauthAccount"] as? [String: Any])
        XCTAssertEqual(account["emailAddress"] as? String, "new@example.com")
        XCTAssertEqual(account["accountUuid"] as? String, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(account["organizationName"] as? String, "New Org")
        XCTAssertEqual(account["hasExtraUsageEnabled"] as? Bool, false)
        XCTAssertEqual(account.count, replacement.count)
    }

    func testKeepsEveryOtherKeyUnchanged() throws {
        var expected = try parse(original)
        var result = try rewrite(original)
        expected["oauthAccount"] = nil
        result["oauthAccount"] = nil
        XCTAssertEqual(NSDictionary(dictionary: result), NSDictionary(dictionary: expected))
    }

    func testKeepsBooleansAndNullsAsSuch() throws {
        let result = try rewrite(original)
        let onboarding = try XCTUnwrap(result["hasCompletedOnboarding"] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(onboarding), CFBooleanGetTypeID())
        let projects = try XCTUnwrap(result["projects"] as? [String: Any])
        let project = try XCTUnwrap(projects["/Users/me/code/app"] as? [String: Any])
        XCTAssertTrue(project["lastSessionId"] is NSNull)
    }

    func testAddsTheBlockWhenItIsMissing() throws {
        let result = try rewrite(#"{"numStartups": 1}"#)
        XCTAssertEqual(result["numStartups"] as? Int, 1)
        let account = try XCTUnwrap(result["oauthAccount"] as? [String: Any])
        XCTAssertEqual(account["emailAddress"] as? String, "new@example.com")
    }
}
