# The Universal Modern macOS App Playbook

This document is a comprehensive master guide for bootstrapping, architecting, and deploying modern native macOS applications. Extracted from best practices and production-ready deployments (like CCSwitcher), it serves as a universal blueprint for both lightweight Menubar utilities and full-featured desktop applications.

---

## 1. Project Management: The "Single Source of Truth"

Never manually create or modify an Xcode project file (`.xcodeproj`). It inevitably leads to Git merge conflicts, broken configurations, and fragile team collaboration.

- **The Tool**: Use [XcodeGen](https://github.com/yonaskolb/XcodeGen) (or Tuist).
- **The Core Principle**: Define your entire project structure, targets, entitlements, and build settings in a declarative `project.yml` file at the root.
- **Info.plist Management**: Do **not** maintain a static, hardcoded `Info.plist` file. 
  - Let XcodeGen synthesize it dynamically by defining an `info.properties` block in your YAML.
  - Map dynamic variables like `$(MARKETING_VERSION)` directly from the YAML to ensure your App version and your Git tags are always synchronized.
- **Version Control**: Add `*.xcodeproj/` and `*.xcworkspace/` to your `.gitignore`. They are strictly ephemeral build artifacts.
- **The Workflow**: Anyone cloning the repo simply runs `xcodegen generate` to instantly build a pristine, localized Xcode environment.

## 2. App Archetypes & SwiftUI Lifecycle

Modern macOS apps should default to SwiftUI for the UI layer, dipping into `AppKit` (via `NSViewRepresentable` or `AppDelegate`) only when the framework falls short.

### Archetype A: The Standard Windowed App
- Use `WindowGroup { ContentView() }` as the primary scene.
- **Window Management**: Use SwiftUI window modifiers like `.defaultSize()`, `.windowResizability()`, and `.windowStyle(.hiddenTitleBar)` for modern, unified toolbar looks.

### Archetype B: The Menubar-Only Utility (Agent)
- Define `LSUIElement: true` in your `project.yml` properties. This prevents the app from showing up in the Dock or the Force Quit menu.
- Use `MenuBarExtra { ContentView() } label: { Image(systemName: "star") }`.
- **Style**: Use `.menuBarExtraStyle(.window)` for a modern, rounded popover, or `.menuBarExtraStyle(.menu)` for a traditional dropdown list.

### Archetype C: The Hybrid App (Menubar + Main Window)
- If your app lives in the menubar but needs to occasionally open a main dashboard window, you must manually manage the application activation policy.
- Switch `NSApp.setActivationPolicy(.regular)` when the window opens (to show in Dock), and `.accessory` when it closes.

### Common Components
- **Settings**: Utilize SwiftUI's native `Settings { SettingsView() }` scene. On macOS, this automatically hooks into the `Cmd + ,` shortcut and provides a standard Preferences window with native tab styles.
- **Launch at Login**: Use macOS 13+ `ServiceManagement.SMAppService.mainApp.register()`. Do not use the legacy and overly complex `SMLoginItemSetEnabled` helper-app pattern.
- **Deep Linking**: Define `CFBundleURLTypes` in your `project.yml`, and use `.onOpenURL { url in ... }` in your root SwiftUI view to intercept custom scheme invocations.

## 3. Sandboxing & Entitlements

Security configurations fundamentally alter what your app can do. You must define this early in `CCSwitcher.entitlements` and reference it in `project.yml`.

- **App Sandbox (`com.apple.security.app-sandbox`)**: 
  - **Mac App Store (MAS)**: Mandatory. You *must* sandbox your app.
  - **Direct Distribution**: Highly recommended, but optional. If your app needs broad disk access (e.g., reading `~/.ssh` or user-defined arbitrary paths without explicit open dialogs), you may need to **disable** the Sandbox.
- **Hardened Runtime (`com.apple.security.get-task-allow`)**: 
  - **Mandatory for Notarization** outside the App Store. Hardened runtime prevents code injection and memory tampering.
- **Capabilities**: If Sandboxed, explicitly request entitlements for network (`network.client`), camera, microphone, or specific folder access (e.g., Downloads/Documents).

## 4. State Management & Data Persistence

Choose the right persistence layer based on data sensitivity and complexity:

- **Preferences / UI State**: Use SwiftUI's `@AppStorage` (UserDefaults) strictly for non-sensitive, flat data (e.g., theme preference, refresh intervals, boolean toggles).
- **Sensitive Data (Tokens, API Keys, Passwords)**: **Never** write these to flat files. 
  - Use the macOS `Security` framework (Keychain). 
  - Because your app is code-signed, it becomes a "Trusted Application" for the Keychain items it creates. It can read/write them silently without prompting the user for their Mac password.
- **Complex Relational Data**: 
  - Default to **SwiftData** (macOS 14+). It provides a highly ergonomic, purely Swift-native interface over Core Data.
  - Use `@Model` for your data classes and `@Query` in your views for automatic reactivity.

## 5. Automation & CI/CD (GitHub Actions)

Never build production releases manually on your local machine. A local build includes local cache, dirty Git states, and provisioning profile complexities.

- **Runner**: Use GitHub's `macos-14` (or latest) runners.
- **Xcode Version**: Force a specific Xcode version using `maxim-lobanov/setup-xcode` to prevent unexpected build failures when GitHub updates their default runner images.
- **Unsigned Build First**: Run `xcodebuild` with `CODE_SIGN_IDENTITY=""` and `CODE_SIGNING_REQUIRED=NO`. This cleanly bypasses Xcode's strict, GUI-focused provisioning profile checks in headless CI environments.
- **Manual Codesign**: Post-build, use the `codesign` CLI tool to inject the `Developer ID Application` certificate, enabling the Hardened Runtime (`--options runtime`).

## 6. Packaging & Distribution

macOS users expect apps to be delivered as `.dmg` files. 

### Direct Distribution (Outside App Store)
1. **Certificates**: Export your Developer ID Application `.p12` certificate. Store it as a Base64 string in GitHub Secrets. Create a temporary Keychain in CI to import it.
2. **DMG Creation**: Use the OSS `create-dmg` tool to package the `.app`. Configure the window size, background, and the native "Drag to Applications folder" symlink arrow.
3. **Notarization (Crucial)**: Upload the signed DMG to Apple using `xcrun notarytool submit` (requires an App-Specific Password). Without this, macOS Gatekeeper will block the app as "Malicious Software".
4. **Stapling**: Run `xcrun stapler staple` on the DMG. This embeds the offline verification ticket into the file so it can be installed without an internet connection.
5. **GitHub Releases**: Tie the CI to `tags: ['v*']`. Use `softprops/action-gh-release` to automatically attach the stapled `.dmg` to a GitHub Release.

### Mac App Store (MAS) Distribution
- Requires a `Mac App Distribution` certificate and a specific Provisioning Profile.
- Generates a `.pkg` instead of a `.dmg`.
- Does **not** require manual Notarization (`notarytool`), as Apple performs this during the App Store Connect review process.

## 7. In-App Auto Updates

If distributing directly (not via App Store), you must provide an update mechanism so users don't get stranded on old versions.

- **The Lightweight Approach (GitHub Releases)**:
  - Query the GitHub API (`https://api.github.com/repos/{owner}/{repo}/releases/latest`).
  - Compare the remote tag against your local `CFBundleShortVersionString`.
  - Prompt via `NSAlert` and use `NSWorkspace.shared.open()` to redirect the user to the GitHub Release `.dmg` download URL.
  - *Pros*: Zero backend infrastructure, completely free.
  - *Cons*: Requires the user to download a DMG, mount it, and overwrite the old `.app` manually.
- **The Industry Standard Approach (Sparkle)**:
  - Integrate the [Sparkle](https://sparkle-project.org/) framework.
  - Sparkle handles binary patching (delta updates), verifying EdDSA cryptographic signatures of the update, and automatically replacing the `.app` in place while restarting the app.
  - Required if you want a true "1-click silent update" experience.

## 8. Aesthetics & Polish

A native macOS app must look and feel like it belongs on the system.

- **Iconography**: macOS icons (Big Sur and later) must be "Squircles" (Superellipses) with specific proportions. 
  - They should **not** fill the entire 1024x1024 canvas. 
  - Scale the core graphic to ~824x824, center it, and apply a soft drop shadow. 
- **Asset Catalogs**: Use automated scripts to generate all required resolutions (`16x16` up to `1024x1024` in `1x` and `2x` scales) and their corresponding `Contents.json` to form a valid `.appiconset`.
- **Translucency & Materials**: Liberally use `.background(.regularMaterial)` or `.ultraThinMaterial` in SwiftUI to get the native macOS frosted-glass blur effects that adapt to the user's desktop wallpaper and Dark Mode settings.

---
*Maintained as the core standard for macOS engineering.*