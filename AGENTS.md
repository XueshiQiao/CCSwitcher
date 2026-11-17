# CCSwitcher Agent Guidelines

**Rules**:
- `project.yml` is the ONLY source of truth. NEVER edit `.pbxproj` or `Info.plist` directly. Run `xcodegen generate` after changes.
- `CCSwitcher.xcodeproj` is disposable (git-ignored).

**App**: Minimalist macOS menu bar app for managing/switching Claude Code accounts.
**Features**: Terminal-free login (Process/Pipe interception), zero-interaction token refresh (`security` CLI workaround), API usage tracking.

**Architecture & Files**:
- **Docs**: `ARCHITECTURE.md` (token flow), `BUILD_GUIDE.md`, `project.yml` (Xcode config).
- **Entry**: `CCSwitcherApp.swift` (MenuBarExtra, lifecycle), `AppState.swift` (@MainActor state).
- **Services**: 
  - `ClaudeService.swift`: Wraps `claude` CLI (auth/status).
  - `KeychainService.swift`: Manages OAuth tokens via `/usr/bin/security`.
  - `*Parser.swift`: Parses `~/.claude/` JSON caches (Activity/Cost/Stats).
- **Models**: `Account.swift`, `*Data.swift` (usage/cost/activity).
- **Views**: `MainMenuView.swift` (dropdown), `SettingsView.swift` (native window), `HiddenWindowView.swift` (LSUIElement keepalive workaround).
- **More Apps**: the Settings tab listing the author's other apps, with a Get button that downloads, verifies, installs and opens one. All of it comes from the shared `MoreAppsKit` Swift package (the sibling apps embed it too). This app adds only `Services/MoreAppsHost.swift` (owns the package's model, plus `SettingsNavigation` so the status menu and the About tab can open that tab) and the tab itself in `SettingsView.swift`. The package's analytics events are deliberately NOT forwarded: the app promises its users that only launch counts are sent.
