import SwiftUI
import ServiceManagement

/// Settings window for configuring the app.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updateChecker: UpdateChecker
    @EnvironmentObject private var menuBarConfig: MenuBarConfig
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @AppStorage("autoSwitchEnabled") private var autoSwitchEnabled = false
    @AppStorage("autoSwitchThreshold") private var autoSwitchThreshold = 90.0
    @State private var launchAtLogin = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            menuBarTab
                .tabItem {
                    Label("Menu Bar", systemImage: "menubar.rectangle")
                }

            ClaudeCLITabView()
                .tabItem {
                    Label("Claude CLI", systemImage: "terminal")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 440)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                Picker("Auto-refresh interval", selection: $refreshInterval) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                }
                .onChange(of: refreshInterval) { _, newValue in
                    appState.startAutoRefresh(interval: newValue)
                }
            }

            Section("Auto-switch") {
                Toggle("Switch account before hitting the limit", isOn: $autoSwitchEnabled)
                if autoSwitchEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Switch at")
                            Spacer()
                            Text("\(Int(autoSwitchThreshold))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $autoSwitchThreshold, in: 50...99, step: 1)
                    }
                    Text("When the active account's 5-hour or weekly usage reaches this level, CCSwitcher switches to the account with the most quota left. Checked on every refresh; a 5-minute cooldown prevents rapid flip-flopping.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Account display") {
                Toggle("Show full email address", isOn: $showFullEmail)
            }

            Section("Appearance") {
                Picker("Language", selection: $appLanguage) {
                    Text("Automatic").tag("auto")
                    Divider()
                    Text("English").tag("en")
                    Text("中文（简体）").tag("zh-Hans")
                    Text("日本語").tag("ja")
                    Text("Deutsch").tag("de")
                    Text("Français").tag("fr")
                }
                .onChange(of: appLanguage) { _, newValue in
                    applyLanguage(newValue)
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Menu Bar Tab

    private var menuBarTab: some View {
        Form {
            Section("Appearance") {
                Toggle("Show head icon in menu bar", isOn: $menuBarConfig.showsHeadIcon)
            }

            Section("Limit bars") {
                Toggle("Customize limit bar colors", isOn: $menuBarConfig.customizesLimitBarColors)

                // Collapsed while off, so the stock layout keeps the module list
                // and its preview visible without scrolling.
                if menuBarConfig.customizesLimitBarColors {
                    ColorPicker("Session bar color", selection: sessionLimitBarColor, supportsOpacity: false)
                    ColorPicker("Weekly bar color", selection: weeklyLimitBarColor, supportsOpacity: false)
                    ColorPicker("Model weekly bar color", selection: modelWeeklyLimitBarColor, supportsOpacity: false)
                    ColorPicker("Low remaining color", selection: lowRemainingLimitBarColor, supportsOpacity: false)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Low remaining threshold")
                            Spacer()
                            Text("\(Int(menuBarConfig.lowRemainingWarningThreshold))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $menuBarConfig.lowRemainingWarningThreshold, in: 0...100, step: 5)
                        Text("Warns when this much quota or less is left. At 30%, bars turn at 70% used.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                MenuBarModulesSettingsView()
                    .environmentObject(appState)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(.brand)

            Text("CCSwitcher")
                .font(.title2.weight(.bold))

            Text("Claude Code Account Switcher")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button(updateChecker.isChecking ? "Checking..." : "Check for Updates") {
                updateChecker.checkForUpdates(manual: true)
            }
            .disabled(updateChecker.isChecking)
            .padding(.top, 4)

            Spacer()

            Text("Easily switch between Claude Code accounts and monitor usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 2) {
                Link("More apps at xueshi.dev", destination: URL(string: "https://xueshi.dev")!)
                    .font(.caption)
                Text("© 2026 Xueshi Qiao")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func applyLanguage(_ lang: String) {
        // Set AppleLanguages for next launch; .environment(\.locale) handles live update
        if lang == "auto" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enable // revert on failure
        }
    }

    private var sessionLimitBarColor: Binding<Color> {
        colorBinding(
            keyPath: \.sessionLimitBarColorHex,
            fallback: MenuBarConfig.defaultSessionLimitBarColorHex
        )
    }

    private var weeklyLimitBarColor: Binding<Color> {
        colorBinding(
            keyPath: \.weeklyLimitBarColorHex,
            fallback: MenuBarConfig.defaultWeeklyLimitBarColorHex
        )
    }

    private var modelWeeklyLimitBarColor: Binding<Color> {
        colorBinding(
            keyPath: \.modelWeeklyLimitBarColorHex,
            fallback: MenuBarConfig.defaultModelWeeklyLimitBarColorHex
        )
    }

    private var lowRemainingLimitBarColor: Binding<Color> {
        colorBinding(
            keyPath: \.lowRemainingLimitBarColorHex,
            fallback: MenuBarConfig.defaultLowRemainingLimitBarColorHex
        )
    }

    private func colorBinding(keyPath: ReferenceWritableKeyPath<MenuBarConfig, String>, fallback: String) -> Binding<Color> {
        Binding(
            get: {
                Color(hexRGB: menuBarConfig[keyPath: keyPath])
                    ?? Color(hexRGB: fallback)
                    ?? .brand
            },
            set: { color in
                if let hex = color.hexRGB {
                    menuBarConfig[keyPath: keyPath] = hex
                }
            }
        )
    }
}
