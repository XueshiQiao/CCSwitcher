import AppKit
import Combine
import SwiftUI

/// Owns the menu-bar `NSStatusItem` and its floating panel (see `PopoverController`).
///
/// We use `NSStatusItem` directly instead of SwiftUI's `MenuBarExtra` because
/// `MenuBarExtra`'s label is constrained to a single menu-bar-height element
/// and clips taller / multi-element content. Hosting a SwiftUI view inside the
/// status item's button (the pattern iStats / Stats use) lifts that limit.
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: PopoverController?
    // Strongly retained: NSHostingController drives the SwiftUI update loop.
    private var stripController: NSHostingController<AnyView>?
    private var appState: AppState?
    private var menuBarConfig: MenuBarConfig?
    private var currentLocale: Locale = .autoupdatingCurrent
    private var stripRefreshCancellables = Set<AnyCancellable>()
    private var isStripRefreshScheduled = false
    private var installed = false

    func install(appState: AppState, config: MenuBarConfig, locale: Locale) {
        guard !installed else { return }
        installed = true
        self.appState = appState
        self.menuBarConfig = config
        self.currentLocale = locale

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        // The strip reports its true intrinsic width back to us; we mirror it
        // onto the status item so the leading icon / trailing module never clip
        // when content widens (real data, longer countdowns, account name).
        let stripController = NSHostingController(rootView: makeStripView(appState: appState, config: config, locale: locale))
        if #available(macOS 13.0, *) {
            stripController.sizingOptions = [.intrinsicContentSize]
        }
        self.stripController = stripController
        observeStripRefreshes(appState: appState, config: config)

        let stripView = stripController.view
        stripView.translatesAutoresizingMaskIntoConstraints = false

        if let button = statusItem.button {
            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(stripView)
            // Only center the strip — do NOT pin leading/trailing to the button.
            // Pinning width to the button creates a feedback loop: the button
            // starts narrow, the flexible account text truncates to fit, we
            // measure the truncated width, and the status item settles at the
            // truncated size. Letting the strip keep its intrinsic width (via
            // NSHostingController .intrinsicContentSize) and driving
            // `statusItem.length` from the reported width breaks that loop.
            NSLayoutConstraint.activate([
                stripView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                stripView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        self.popover = PopoverController(
            appState: appState,
            config: config,
            locale: locale,
            statusItem: statusItem
        )
    }

    /// Update the locale environment on all hosted SwiftUI views.
    /// Called when the user changes the in-app language setting.
    func updateLocale(_ locale: Locale) {
        currentLocale = locale
        guard let appState, let config = menuBarConfig else { return }
        stripController?.rootView = makeStripView(appState: appState, config: config, locale: locale)
        popover?.updateRoot(appState: appState, config: config, locale: locale)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover?.hide()
            showContextMenu()
        } else {
            popover?.toggle()
        }
    }

    /// Right-click menu on the status item: quick actions without opening the panel.
    private func showContextMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(menuItem(String(localized: "Refresh", bundle: L10n.bundle), #selector(refreshFromMenu), key: "r"))
        menu.addItem(menuItem(String(localized: "Settings", bundle: L10n.bundle), #selector(openSettingsFromMenu), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Quit CCSwitcher", bundle: L10n.bundle), #selector(quitFromMenu), key: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refreshFromMenu() {
        guard let appState else { return }
        Task { await appState.refresh() }
    }

    @objc private func openSettingsFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .ccswitcherOpenSettings, object: nil)
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    private func makeStripView(appState: AppState, config: MenuBarConfig, locale: Locale) -> AnyView {
        let statusItem = self.statusItem
        return AnyView(
            MenuBarStripView(
                appState: appState,
                config: config,
                onWidth: { [weak statusItem] width in
                    // Every assignment re-lays out the status item, even an
                    // unchanged one, and the strip is rebuilt on each change.
                    let length = max(width, 1)
                    if let statusItem, statusItem.length != length {
                        statusItem.length = length
                    }
                }
            )
            .environment(\.locale, locale)
        )
    }

    private func observeStripRefreshes(appState: AppState, config: MenuBarConfig) {
        stripRefreshCancellables.removeAll()

        appState.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleStripRefresh()
                }
            }
            .store(in: &stripRefreshCancellables)

        config.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleStripRefresh()
                }
            }
            .store(in: &stripRefreshCancellables)

        // @AppStorage settings the strip reads (e.g. "Show full email") used to
        // be picked up by its 3-second poll; that tick is now once a minute.
        // The notification is posted on whatever thread wrote the default, and
        // this sink is main-actor code: Swift 6 traps if it runs anywhere else.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleStripRefresh()
                }
            }
            .store(in: &stripRefreshCancellables)
    }

    private func scheduleStripRefresh() {
        guard !isStripRefreshScheduled else { return }
        isStripRefreshScheduled = true

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            isStripRefreshScheduled = false
            guard let appState, let config = menuBarConfig else { return }
            stripController?.rootView = makeStripView(
                appState: appState,
                config: config,
                locale: currentLocale
            )
        }
    }
}
