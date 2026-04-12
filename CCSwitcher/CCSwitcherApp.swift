import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App starts as agent/accessory due to LSUIElement
    }
}

@main
struct CCSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("showAccountName") private var showAccountName = true
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    
    @State private var isDoubleUsageActive = false
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CCSwitcherKeepalive") {
            HiddenWindowView()
                .onAppear {
                    // Check for updates silently on app launch
                    updateChecker.checkForUpdates(manual: false)
                    checkDoubleUsage()
                    // Kick off background usage tracking immediately upon app start
                    Task {
                        await appState.refresh()
                        appState.startAutoRefresh(interval: refreshInterval)
                    }
                }
                .onReceive(timer) { _ in
                    checkDoubleUsage()
                }
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MainMenuView()
                .environmentObject(appState)
                .environmentObject(updateChecker)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updateChecker)
        }
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: isDoubleUsageActive ? "brain.head.profile.fill" : "brain.head.profile")
            if showAccountName {
                if let account = appState.activeAccount {
                    Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                        .font(.caption)
                }
            }
        }
    }
    
    private func checkDoubleUsage() {
        let date = Date()
        let calendar = Calendar(identifier: .gregorian)
        
        var promoStartComponents = DateComponents()
        promoStartComponents.year = 2026
        promoStartComponents.month = 3
        promoStartComponents.day = 13
        
        var promoEndComponents = DateComponents()
        promoEndComponents.year = 2026
        promoEndComponents.month = 3
        promoEndComponents.day = 29 // up to March 28 inclusive
        
        guard let start = calendar.date(from: promoStartComponents),
              let end = calendar.date(from: promoEndComponents),
              date >= start && date < end else {
            isDoubleUsageActive = false
            return
        }
        
        guard let etTimeZone = TimeZone(identifier: "America/New_York") else {
            isDoubleUsageActive = false
            return
        }
        
        var etCalendar = Calendar(identifier: .gregorian)
        etCalendar.timeZone = etTimeZone
        
        let weekday = etCalendar.component(.weekday, from: date)
        // 1 = Sunday, 7 = Saturday
        if weekday == 1 || weekday == 7 {
            isDoubleUsageActive = true
            return
        }
        
        let hour = etCalendar.component(.hour, from: date)
        // 8 AM to 2 PM (14:00) ET is normal. Outside this is double.
        if hour >= 8 && hour < 14 {
            isDoubleUsageActive = false
        } else {
            isDoubleUsageActive = true
        }
    }
}
