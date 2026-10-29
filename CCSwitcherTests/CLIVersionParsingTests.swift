import XCTest

/// `ClaudeService` validates the version it reads from `claude --version` and
/// from the release CDN with these two helpers before showing either one.
final class CLIVersionParsingTests: XCTestCase {
    func testAcceptsDottedNumbers() {
        for version in ["1.0.42", "2.1.139", "10.20", "1.2.3.4"] {
            XCTAssertTrue(ClaudeService.isPureSemver(version), version)
        }
    }

    func testRejectsAnythingElse() {
        let rejected = [
            "",                         // empty
            "7",                        // a single number is not a version
            "1..2", ".1.2", "1.2.",     // empty components
            "v1.2.3", "1.2.3-beta",     // prefixes and suffixes
            "１.２.３",                  // non-ASCII digits
            "<html>1.2.3</html>",       // an error page served with status 200
            String(repeating: "1.", count: 16) + "1", // longer than 32 characters
        ]
        for text in rejected {
            XCTAssertFalse(ClaudeService.isPureSemver(text), text)
        }
    }

    func testExtractsTheVersionFromCLIOutput() {
        XCTAssertEqual(ClaudeService.extractSemver(from: "1.0.42 (Claude Code)"), "1.0.42")
        XCTAssertEqual(ClaudeService.extractSemver(from: "claude 2.1.139\n"), "2.1.139")
    }

    func testSkipsNumbersThatAreNotVersions() {
        XCTAssertEqual(ClaudeService.extractSemver(from: "build 7, version 1.2.3"), "1.2.3")
    }

    func testReturnsNilWithoutAVersion() {
        XCTAssertNil(ClaudeService.extractSemver(from: "command not found: claude"))
        XCTAssertNil(ClaudeService.extractSemver(from: ""))
    }
}
