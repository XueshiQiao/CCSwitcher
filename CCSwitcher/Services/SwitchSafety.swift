import Foundation

/// A switch whose two credential writes (keychain token, then the
/// `~/.claude.json` identity) were started but not seen to finish. Written
/// just before the first write and cleared once the switch has an outcome,
/// so a marker found at launch means the app died in between.
struct PendingSwitch: Codable {
    let from: UUID
    let to: UUID
    var startedAt = Date()

    /// Older markers are ignored: by then the user may have signed in some
    /// other way, and finishing the old switch would undo that.
    static let maxAge: TimeInterval = 600

    /// A small file rather than a UserDefaults key: the switch runs off the
    /// main thread, and a defaults write there posts
    /// `UserDefaults.didChangeNotification` on that thread to every observer.
    private static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("CCSwitcher/pending-switch.json")
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> PendingSwitch? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingSwitch.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

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
