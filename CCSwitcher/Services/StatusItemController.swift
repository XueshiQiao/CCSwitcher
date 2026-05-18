import AppKit
import SwiftUI

/// Owns the menu-bar `NSStatusItem` and its click-through `NSPopover`.
///
/// We use `NSStatusItem` directly instead of SwiftUI's `MenuBarExtra` because
/// `MenuBarExtra`'s label is constrained to a single menu-bar-height element
/// and clips taller / multi-element content. Hosting a SwiftUI view inside the
/// status item's button (the pattern iStats / Stats use) lifts that limit.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    // Strongly retained: NSHostingController drives the SwiftUI update loop.
    private var stripController: NSHostingController<AnyView>?
    private var popoverController: NSHostingController<AnyView>?
    private var appState: AppState?
    private var menuBarConfig: MenuBarConfig?
    private var installed = false

    func install(appState: AppState, config: MenuBarConfig, locale: Locale) {
        guard !installed else { return }
        installed = true
        self.appState = appState
        self.menuBarConfig = config

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        // The strip reports its true intrinsic width back to us; we mirror it
        // onto the status item so the leading icon / trailing module never clip
        // when content widens (real data, longer countdowns, account name).
        let strip = MenuBarStripView(
            appState: appState,
            config: config,
            onWidth: { [weak statusItem] width in
                statusItem?.length = max(width, 1)
            }
        )
        .environment(\.locale, locale)

        let stripController = NSHostingController(rootView: AnyView(strip))
        if #available(macOS 13.0, *) {
            stripController.sizingOptions = [.intrinsicContentSize]
        }
        self.stripController = stripController

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
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let popoverController = NSHostingController(
            rootView: AnyView(
                MainMenuView()
                    .environmentObject(appState)
                    .environment(\.locale, locale)
            )
        )
        if #available(macOS 13.0, *) {
            popoverController.sizingOptions = [.preferredContentSize]
        } else {
            popoverController.preferredContentSize = NSSize(width: 360, height: 520)
        }
        popover.contentViewController = popoverController
        popover.delegate = self
        self.popover = popover
        self.popoverController = popoverController
    }

    /// Update the locale environment on all hosted SwiftUI views.
    /// Called when the user changes the in-app language setting.
    func updateLocale(_ locale: Locale) {
        guard let appState, let config = menuBarConfig else { return }
        stripController?.rootView = AnyView(
            MenuBarStripView(
                appState: appState,
                config: config,
                onWidth: { [weak statusItem] width in
                    statusItem?.length = max(width, 1)
                }
            )
            .environment(\.locale, locale)
        )
        popoverController?.rootView = AnyView(
            MainMenuView()
                .environmentObject(appState)
                .environment(\.locale, locale)
        )
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
