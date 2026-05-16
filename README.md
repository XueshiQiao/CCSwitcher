<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English%20✓-blue" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-gray" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語-gray" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch-gray" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français-gray" alt="Français"></a>
</p>

<p align="center">
  <a href="https://github.com/XueshiQiao/CCSwitcher/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/XueshiQiao/CCSwitcher/build.yml?branch=main&label=build" alt="Build Status"></a>
  <a href="https://github.com/XueshiQiao/CCSwitcher/releases/latest"><img src="https://img.shields.io/github/v/release/XueshiQiao/CCSwitcher?label=release&color=blue" alt="Latest Release"></a>
  <a href="https://github.com/XueshiQiao/CCSwitcher/releases"><img src="https://img.shields.io/github/downloads/XueshiQiao/CCSwitcher/total?label=downloads&color=brightgreen" alt="Downloads"></a>
  <a href="https://github.com/XueshiQiao/homebrew-tap"><img src="https://img.shields.io/badge/homebrew-ccswitcher-FBB040?logo=homebrew&logoColor=white" alt="Homebrew"></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-000000?logo=apple&logoColor=white" alt="macOS 14.0+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
</p>

# CCSwitcher

CCSwitcher is a lightweight, pure menu bar macOS application designed to help developers manage and switch between multiple Claude Code accounts **without interrupting your multi-account workflow**. The native `claude auth login` flow is destructive — every switch wipes the previous account's credentials and forces another full browser OAuth. CCSwitcher keeps a per-account backup of every credential, atomically swaps the keychain entry and `~/.claude.json` on switch, and all accounts stay available for one-click swap-back. CCSwitcher also monitors API usage, gracefully handles background token refreshes, and circumvents common macOS menu bar app limitations.

## Features

- **Non-Interruptive Account Switching**: The native `claude auth logout` clears the current account's credentials, and switching back requires another full OAuth. CCSwitcher keeps a separate backup of each account (keychain token + `~/.claude.json` `oauthAccount` block), atomically swaps both on switch — every added account's credentials stay intact, one-click swap-back, no workflow interruption. (Note: an in-flight `claude` session will pick up the newly-switched credentials on its next API call — this is Claude CLI behavior, not something CCSwitcher controls.)
- **Multi-Account Management**: Add and switch between different Claude Code accounts with a single click from the macOS menu bar.
- **Usage Dashboard**: Real-time monitoring of your Claude API usage limits (5-hour session and weekly) directly in the menu bar dropdown, plus today's API-equivalent cost and activity stats (turns, active minutes, lines written, model breakdown).
- **Configurable Menu Bar Modules**: Build your own iStats-style menu bar readout. Choose any combination of account name, 5-hour session usage, weekly usage, today's cost, and session/weekly reset countdowns — each rendered as a compact two-line module (label over value, with monochrome progress bars for utilization). Drag to reorder and toggle modules in Settings, with a live preview.
- **Desktop Widgets**: Native macOS desktop widgets in small, medium, and large sizes showing account usage, costs, and activity stats. Includes a circular ring variant for at-a-glance usage monitoring.
- **In-App Auto-Update**: Powered by [Sparkle 2.x](https://sparkle-project.org/). New versions install silently and atomically — no DMG dragging, no Finder dialogs.
- **Dark Mode**: Full light and dark mode support with adaptive colors that follow your system appearance.
- **Internationalization**: Available in English, 简体中文 (Chinese), 日本語 (Japanese), Deutsch (German), and Français (French).
- **Privacy-Focused UI**: Automatically obfuscates email addresses and account names in screenshots or screen recordings to protect your identity.
- **Zero-Interaction Token Refresh**: Intelligently handles Claude's OAuth token expiration by delegating the refresh process to the official CLI in the background.
- **Seamless Login Flow**: Add new accounts without ever opening a terminal. The app silently invokes the CLI and handles the browser OAuth loop for you.
- **System-Native UX**: A clean, native SwiftUI interface that behaves exactly like a first-class macOS menu bar utility, complete with a fully functional settings window.

## Screenshots

<p align="center">
  <img src="assets/CCSwitcher-light.png" alt="CCSwitcher — Light Theme" width="900" /><br/>
  <em>Light Theme</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-dark.png" alt="CCSwitcher — Dark Theme" width="900" /><br/>
  <em>Dark Theme</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-widgets.png" alt="CCSwitcher — Desktop Widget" width="900" /><br/>
  <em>Desktop Widget</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-menubar-modules.png" alt="CCSwitcher — Configurable Menu Bar Modules" width="900" /><br/>
  <em>Configurable menu bar modules — account, session/weekly usage, daily cost, and reset countdowns</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-menubar-settings.png" alt="CCSwitcher — Menu Bar Module Settings" width="640" /><br/>
  <em>Drag to reorder and toggle modules, with a live preview</em>
</p>

## Demo

<p align="center">
  <video src="https://github.com/user-attachments/assets/ca37eaae-e8d8-4557-995e-bc154442c833" width="864" autoplay loop muted playsinline />
</p>

## Key Features & Architecture

CCSwitcher employs several specific architectural strategies, some uniquely tailored to its operation and others drawing inspiration from the open-source community (notably [CodexBar](https://github.com/steipete/CodexBar)).

### 1. Non-Interruptive Account Switching

The headline feature: **CCSwitcher preserves every added account's credentials, so switching never interrupts your multi-account workflow.**

The native CLI has no clean "switch account" command — `claude auth logout && claude auth login` clears the current account's keychain entry and triggers a full browser OAuth round-trip; switching back to the previous account means another full OAuth. CCSwitcher takes a different path:

- Each previously-added account is stored in CCSwitcher's own per-account backup (`~/.ccswitcher/backups.json`), containing the OAuth token JSON and the matching `oauthAccount` block from `~/.claude.json`.
- When the user picks a different account, CCSwitcher atomically (a) writes the target account's token to the macOS Keychain entry `Claude Code-credentials`, and (b) overwrites the `oauthAccount` block in `~/.claude.json`. Both writes happen via Foundation file APIs — no destructive logout/login side effects.
- Result: every added account's credentials stay intact in the backup, available for one-click swap-back without re-OAuth. New `claude` invocations immediately use the newly-selected account.

**About in-flight sessions**: CCSwitcher only swaps credentials on disk; it doesn't communicate with any running `claude` process. If you switch accounts mid-session, that session's next API call will use the freshly-swapped credentials — this is the Claude CLI's behavior (it re-reads the keychain on every call), not something CCSwitcher controls. If you need an in-flight session to finish on its original account, end it before switching.

### 2. Terminal-Free Login Flow (Native `Process` + `Pipe`)

Unlike tools that build complex pseudoterminals (PTYs) to handle CLI login states, CCSwitcher uses a minimalist approach to add new accounts:

- We rely on native `Process` and standard `Pipe()` redirection.
- When `claude auth login` is executed silently in the background, the Claude CLI detects the non-interactive environment and automatically launches the system's default browser to handle the OAuth loop.
- Once the user authorizes in the browser, the background CLI process terminates with exit code 0. CCSwitcher then captures the newly-generated keychain credentials and `oauthAccount` block — the user never opens a terminal.

### 3. Delegated Token Refresh (A Different Path Than CodexBar)

Claude's OAuth access tokens have a short lifespan (~8 hours) and the refresh endpoint is protected by the Claude CLI's internal client signatures and Cloudflare. Third-party apps that want silent auto-refresh have two paths, and CCSwitcher and [CodexBar](https://github.com/steipete/CodexBar) take **fundamentally different** approaches here:

- **CodexBar's approach**: directly POST to Anthropic's non-public OAuth refresh endpoint (`https://platform.claude.com/v1/oauth/token`) with a hardcoded `client_id` (`9d1c250a-…`, extracted from the Claude CLI binary) plus the `refresh_token` from the keychain, then parse the response and write the new tokens back themselves. Pros: no subprocess, fast. Cons: this endpoint and client_id are **not** officially documented by Anthropic — if they rotate the client_id, change the endpoint, or add client attestation, refresh silently breaks until the next app update ships.
- **CCSwitcher's approach**: listen for `HTTP 401: token_expired` from the Anthropic Usage API; when caught, launch a silent background `claude auth status` — a read-only command — which lets the official Claude CLI use **its own, Anthropic-maintained** refresh logic to fetch a new token and write it back to the keychain. CCSwitcher re-reads the keychain and retries the usage fetch.

We deliberately chose the latter, trading a tiny per-refresh subprocess overhead for two real wins:

1. **Safer**: refresh goes through Anthropic's own CLI auth mechanism. CCSwitcher never holds or replays their internal `client_id`. If Anthropic adds stricter client-side checks (e.g. binary attestation), we automatically inherit them with no app update needed.
2. **Future-proof**: endpoint, client_id, token format — none of it is ours to maintain. CLI upgrades automatically deliver new refresh logic.

The user-visible result is the same as CodexBar's: seamless, zero-interaction. The difference is **who's on the hook for keeping up with Anthropic's private OAuth surface** — CodexBar takes that on themselves (faster, riskier); CCSwitcher delegates to the official CLI (small subprocess cost, safer).

### 4. Local JSONL Parse Cache (Performance)

Cost summaries and today's-activity stats are computed from Claude Code's per-session JSONL files under `~/.claude/projects/`. A heavy user's directory can be hundreds of megabytes across thousands of files. Re-parsing the whole tree every 5 minutes was originally CPU-pegging on idle ([#13](https://github.com/XueshiQiao/CCSwitcher/issues/13)).

- CCSwitcher maintains a persistent per-file parse cache at `~/Library/Application Support/CCSwitcher/session-parse-cache.json`, keyed by file mtime.
- On each refresh, files with unchanged mtime are skipped entirely — the cache holds their previously-parsed aggregates and the result is summed in memory.
- Only the actively-modified files (typically just your current Claude Code session) get re-parsed. Steady-state refreshes drop from ~5 seconds of saturated CPU to under 100ms.

### 5. Security-CLI Keychain Reader

Reading from the macOS Keychain via native `Security.framework` (`SecItemCopyMatching`) from a background menu bar app sometimes surfaces a blocking system UI prompt — "CCSwitcher wants to access your keychain". To bypass this, CCSwitcher adopts CodexBar's strategy:

- We execute the system-bundled tool `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`.
- When macOS prompts the user *the first time*, the user clicks **"Always Allow"**. Because the request comes from a system binary rather than our signed app, the grant persists permanently.
- Subsequent background polling is completely silent.

**About CCSwitcher's own backup keychain entries**: the per-account backup store (`me.xueshi.ccswitcher.backups`) is a keychain entry CCSwitcher creates and owns, so there's no cross-vendor prompt to dodge. We read/write it via the native `Security.framework` (`SecItemCopyMatching` / `SecItemAdd`) — no subprocess, no prompt. In short: **the `/usr/bin/security` subprocess approach is reserved specifically for the cross-vendor read of Claude Code's keychain entry; everything else uses the most direct native API.**

### 6. Team-ID-Prefixed App Group (No "Access Data From Other Apps" Prompt)

macOS 15 Sequoia silently changed the rules for App Group containers: any non-Mac-App-Store, non-TestFlight app whose App Group ID does NOT begin with the developer Team ID triggers a TCC "App Management" prompt on every launch (and again after every auto-update that changes the binary's cdhash). To avoid this, CCSwitcher's App Group is identified as `584KQTRF3B.me.xueshi.ccswitcher` — the Team-ID-prefixed form, which macOS auto-authorizes for Developer-ID-signed apps without a provisioning profile. See [#14](https://github.com/XueshiQiao/CCSwitcher/issues/14) for the full investigation.

### 7. SwiftUI `Settings` Window Lifecycle Keepalive for `LSUIElement`

Because CCSwitcher is a pure menu bar app (`LSUIElement = true`), SwiftUI refuses to present the native `Settings { … }` window — a known macOS quirk where SwiftUI assumes the app has no active scene to attach Settings to. CCSwitcher implements CodexBar's **lifecycle keepalive** workaround:

- On launch, the app creates a `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }`.
- `HiddenWindowView` intercepts its underlying `NSWindow` and makes it a 1×1 pixel, completely transparent, click-through window positioned off-screen at `(-5000, -5000)`.
- Because this "ghost window" exists, SwiftUI is convinced the app has an active scene. When the user clicks the gear icon, we post a `Notification` that the ghost window catches to trigger `@Environment(\.openSettings)`, producing a perfectly functioning native Settings window.
