<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English%20✓-blue" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-gray" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語-gray" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch-gray" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français-gray" alt="Français"></a>
</p>

# CCSwitcher

CCSwitcher is a lightweight, pure menu bar macOS application designed to help developers seamlessly manage and switch between multiple Claude Code accounts. It monitors API usage, gracefully handles background token refreshes, and circumvents common macOS menu bar app limitations.

## Features

- **Multi-Account Management**: Easily add and switch between different Claude Code accounts with a single click from the macOS menu bar.
- **Usage Dashboard**: Real-time monitoring of your Claude API usage limits (session and weekly) directly in the menu bar dropdown.
- **Desktop Widgets**: Native macOS desktop widgets in small, medium, and large sizes showing account usage, costs, and activity stats. Includes a circular ring variant for at-a-glance usage monitoring.
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

## Demo

https://github.com/XueshiQiao/CCSwitcher/raw/main/assets/CCSwitcher-screen-high-quality-1.1.0.mp4

## Key Features & Architecture

This application employs several specific architectural strategies, some uniquely tailored to its operation and others drawing inspiration from the open-source community.

### 1. Minimalist Login Flow (Native `Pipe` Interception)

Unlike other tools that build complex pseudoterminals (PTY) to handle CLI login states, CCSwitcher uses a minimalist approach to add new accounts:
- We rely on native `Process` and standard `Pipe()` redirection.
- When `claude auth login` is executed silently in the background, the Claude CLI is smart enough to detect a non-interactive environment and automatically launches the system's default browser to handle the OAuth loop.
- Once the user authorizes in the browser, the background CLI process naturally terminates with a success exit code (0), allowing our app to resume its flow and capture the newly generated keychain credentials without ever requiring the user to open a terminal application.

### 2. Delegated Token Refresh (Inspired by CodexBar)

Claude's OAuth access tokens have a very short lifespan (typically 1-2 hours) and the refresh endpoint is protected by Claude CLI's internal client signatures and Cloudflare. To solve this, we use a **Delegated Refresh** pattern inspired by the excellent work in [CodexBar](https://github.com/lucas-clemente/codexbar):
- Instead of the app trying to manually refresh the token via HTTP requests, we listen for `HTTP 401: token_expired` errors from the Anthropic Usage API.
- When a 401 is caught, CCSwitcher immediately launches a silent background process running `claude auth status`.
- This simple read-only command forces the official Claude Node.js CLI to wake up, realize the token is expired, and securely negotiate a new token using its own internal logic. 
- The official CLI writes the refreshed token back into the macOS Keychain. CCSwitcher then immediately re-reads the Keychain and successfully retries the usage fetch, achieving a 100% seamless, zero-interaction token refresh.

### 3. Experimental Security CLI Keychain Reader (Inspired by CodexBar)

Reading from the macOS Keychain via native `Security.framework` (`SecItemCopyMatching`) from a background menu bar app often triggers aggressive and blocking system UI prompts ("CCSwitcher wants to access your keychain"). 
- To bypass this UX hurdle, we again adapted a strategy from **CodexBar**:
- We execute the macOS built-in command line tool: `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`.
- When macOS prompts the user for this access the *first time*, the user can click **"Always Allow"**. Because the request comes from a core system binary (`/usr/bin/security`) rather than our signed app binary, the system permanently remembers this grant.
- Subsequent background polling operations are completely silent, eliminating prompt storms.

### 4. SwiftUI `Settings` Window Lifecycle Keepalive for `LSUIElement` (Inspired by CodexBar)

Because CCSwitcher is a pure menu bar app (`LSUIElement = true` in `Info.plist`), SwiftUI refuses to present the native `Settings { ... }` window. This is a known macOS bug where SwiftUI assumes the app has no active interactive scenes to attach the settings window to.
- We implemented CodexBar's **Lifecycle Keepalive** workaround.
- On launch, the app creates a `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }`.
- The `HiddenWindowView` intercepts its underlying `NSWindow` and makes it a 1x1 pixel, completely transparent, click-through window positioned off-screen at `x: -5000, y: -5000`.
- Because this "ghost window" exists, SwiftUI is tricked into believing the app has an active scene. When the user clicks the gear icon, we post a `Notification` that the ghost window catches to trigger `@Environment(\.openSettings)`, resulting in a perfectly functioning native Settings window.
