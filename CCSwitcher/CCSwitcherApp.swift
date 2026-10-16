import SwiftUI

private let log = FileLog("App")

class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        // Apply saved language preference before any UI loads
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        if lang != "auto" {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App starts as agent/accessory due to LSUIElement
    }

    /// Longest quit waits for the cache save before exiting without it.
    private static let terminateTimeout: Duration = .seconds(15)

    /// True from returning `.terminateLater` until its one reply is sent.
    /// Main-actor state, so the flush and the timeout cannot both reply.
    private var terminateReplyPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Session parse cache saves are throttled, so write whatever is
        // still pending before exiting. The save runs on the cache actor,
        // off the main thread. Termination resumes once it finishes, or
        // after `terminateTimeout` if it hasn't, so a stuck save cannot
        // hold quit open. Cutting it short only costs the cache, which is
        // rebuilt from the transcripts at next launch.
        if terminateReplyPending { return .terminateLater }
        terminateReplyPending = true

        let timeout = Task {
            try? await Task.sleep(for: Self.terminateTimeout)
            guard !Task.isCancelled, self.terminateReplyPending else { return }
            self.terminateReplyPending = false
            log.warning("Quit: cache save still running after 15 s; quitting without waiting for it")
            // FileLog writes asynchronously; give the line a moment to land.
            try? await Task.sleep(for: .milliseconds(250))
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await SessionParseCacheV2.shared.flush()
            timeout.cancel()
            guard self.terminateReplyPending else { return }
            self.terminateReplyPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CCSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var menuBarConfig = MenuBarConfig.shared
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("appLanguage") private var appLanguage = "auto"

    @State private var statusItemController = StatusItemController()
    @State private var didBootstrap = false

    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CCSwitcherKeepalive") {
            HiddenWindowView()
                .onAppear {
                    guard !didBootstrap else { return }
                    didBootstrap = true
                    // Sparkle's SPUStandardUpdaterController(startingUpdater: true)
                    // schedules its own background update checks; no need to
                    // call checkForUpdates here.
                    _ = updateChecker
                    statusItemController.install(
                        appState: appState,
                        config: menuBarConfig,
                        locale: currentLocale
                    )
                    // Kick off background usage tracking immediately upon app start
                    Task {
                        await appState.refresh()
                        appState.startAutoRefresh(interval: refreshInterval)
                    }
                }
                .onChange(of: appLanguage) { _, _ in
                    statusItemController.updateLocale(currentLocale)
                }
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updateChecker)
                .environmentObject(menuBarConfig)
                .environment(\.locale, currentLocale)
        }
    }

    private var currentLocale: Locale {
        appLanguage == "auto" ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }
}
