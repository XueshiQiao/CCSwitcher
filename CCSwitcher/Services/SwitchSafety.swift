import Foundation

/// Lets quit wait for an in-flight switch: exiting between its keychain and
/// `~/.claude.json` writes leaves one account's token under another's identity.
@MainActor
enum CredentialWriteGate {
    static var isBusy = false

    /// Returns once no switch is running, or after `timeout`.
    static func waitUntilIdle(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while isBusy, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
