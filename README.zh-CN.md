<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/English-gray" alt="English"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文%20✓-blue" alt="简体中文"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/日本語-gray" alt="日本語"></a>
  <a href="README.de.md"><img src="https://img.shields.io/badge/Deutsch-gray" alt="Deutsch"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Français-gray" alt="Français"></a>
</p>

# CCSwitcher

CCSwitcher 是一款轻量级的纯 macOS 菜单栏应用程序，旨在帮助开发者无缝管理和切换多个 Claude Code 账户。它可以监控 API 使用情况，优雅地处理后台 token 刷新，并解决常见的 macOS 菜单栏应用限制问题。

## 功能特性

- **多账户管理**：在 macOS 菜单栏中一键添加和切换不同的 Claude Code 账户。
- **用量仪表盘**：直接在菜单栏下拉菜单中实时监控 Claude API 使用限额（会话和每周）。
- **桌面小组件**：原生 macOS 桌面小组件，支持小、中、大三种尺寸，展示账户用量、费用和活动统计。还包含环形变体，方便一目了然地监控使用情况。
- **深色模式**：完整支持亮色和深色模式，自适应颜色随系统外观自动切换。
- **国际化**：支持 English、简体中文、日本語、Deutsch 和 Français 五种语言。
- **隐私保护界面**：在截图或屏幕录制中自动模糊处理邮箱地址和账户名称，保护您的身份信息。
- **零交互 Token 刷新**：通过将刷新过程委托给后台运行的官方 CLI，智能处理 Claude 的 OAuth token 过期问题。
- **无缝登录流程**：无需打开终端即可添加新账户。应用在后台静默调用 CLI 并为您处理浏览器 OAuth 流程。
- **系统原生体验**：简洁的原生 SwiftUI 界面，表现完全如同一流的 macOS 菜单栏工具，配备功能完整的设置窗口。

## 截图

<p align="center">
  <img src="assets/CCSwitcher-light.png" alt="CCSwitcher — Light Theme" width="900" /><br/>
  <em>浅色主题</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-dark.png" alt="CCSwitcher — Dark Theme" width="900" /><br/>
  <em>深色主题</em>
</p>

<p align="center">
  <img src="assets/CCSwitcher-widgets.png" alt="CCSwitcher — Desktop Widget" width="900" /><br/>
  <em>桌面小组件</em>
</p>

## 演示

https://github.com/XueshiQiao/CCSwitcher/raw/main/assets/CCSwitcher-screen-high-quality-1.1.0.mp4

## 核心特性与架构

本应用采用了多种特定的架构策略，其中一些是为其独特运行方式量身定制的，另一些则借鉴了开源社区的灵感。

### 1. 极简登录流程（原生 `Pipe` 拦截）

与其他构建复杂伪终端（PTY）来处理 CLI 登录状态的工具不同，CCSwitcher 使用极简方式添加新账户：
- 我们依赖原生 `Process` 和标准 `Pipe()` 重定向。
- 当 `claude auth login` 在后台静默执行时，Claude CLI 能够智能检测到非交互式环境，并自动启动系统默认浏览器来处理 OAuth 流程。
- 用户在浏览器中完成授权后，后台 CLI 进程会以成功退出码（0）自然终止，使应用能够恢复流程并捕获新生成的钥匙串凭证，全程无需用户打开终端应用。

### 2. 委托式 Token 刷新（受 CodexBar 启发）

Claude 的 OAuth access token 生命周期非常短（通常 1-2 小时），且刷新端点受到 Claude CLI 内部客户端签名和 Cloudflare 的保护。为解决此问题，我们采用了受 [CodexBar](https://github.com/lucas-clemente/codexbar) 优秀工作启发的**委托式刷新**模式：
- 应用不会尝试通过 HTTP 请求手动刷新 token，而是监听来自 Anthropic Usage API 的 `HTTP 401: token_expired` 错误。
- 当捕获到 401 错误时，CCSwitcher 立即启动一个静默后台进程运行 `claude auth status`。
- 这个简单的只读命令会迫使官方 Claude Node.js CLI 唤醒，识别到 token 已过期，并使用其内部逻辑安全地协商新 token。
- 官方 CLI 将刷新后的 token 写回 macOS 钥匙串。CCSwitcher 随后立即重新读取钥匙串并成功重试用量请求，实现 100% 无缝、零交互的 token 刷新。

### 3. 实验性 Security CLI 钥匙串读取器（受 CodexBar 启发）

通过原生 `Security.framework`（`SecItemCopyMatching`）从后台菜单栏应用读取 macOS 钥匙串，通常会触发频繁且阻塞的系统 UI 提示（"CCSwitcher 想要访问您的钥匙串"）。
- 为绕过这一用户体验障碍，我们再次借鉴了 **CodexBar** 的策略：
- 我们执行 macOS 内置命令行工具：`/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`。
- 当 macOS *首次*提示用户授权此访问时，用户可以点击**"始终允许"**。由于请求来自核心系统二进制文件（`/usr/bin/security`）而非我们签名的应用二进制文件，系统会永久记住此授权。
- 后续的后台轮询操作将完全静默，消除提示弹窗风暴。

### 4. SwiftUI `Settings` 窗口生命周期保活（适用于 `LSUIElement`，受 CodexBar 启发）

由于 CCSwitcher 是纯菜单栏应用（`Info.plist` 中 `LSUIElement = true`），SwiftUI 拒绝呈现原生 `Settings { ... }` 窗口。这是一个已知的 macOS bug，SwiftUI 认为应用没有活跃的交互式场景来附加设置窗口。
- 我们实现了 CodexBar 的**生命周期保活**解决方案。
- 应用启动时，会创建一个 `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }`。
- `HiddenWindowView` 拦截其底层 `NSWindow`，使其成为一个 1x1 像素、完全透明、可穿透点击的窗口，定位在屏幕外 `x: -5000, y: -5000` 的位置。
- 因为这个"幽灵窗口"的存在，SwiftUI 被欺骗为认为应用拥有活跃的场景。当用户点击齿轮图标时，我们发送一个 `Notification`，幽灵窗口捕获后触发 `@Environment(\.openSettings)`，从而实现完美运作的原生设置窗口。
