import AppKit
import Observation
import SwiftUI

/// Rounded rect with a soft notch (arrow) on the top edge pointing at the status item.
struct PopoverShape: Shape {
    var arrowX: CGFloat
    var arrowHeight: CGFloat = 10
    var radius: CGFloat = 22

    var animatableData: CGFloat {
        get { arrowX }
        set { arrowX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + arrowHeight
        let ax = min(max(arrowX, rect.minX + radius + 22), rect.maxX - radius - 22)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + radius, y: top))
        p.addLine(to: CGPoint(x: ax - 15, y: top))
        p.addCurve(to: CGPoint(x: ax, y: rect.minY),
                   control1: CGPoint(x: ax - 7.5, y: top),
                   control2: CGPoint(x: ax - 6.5, y: rect.minY))
        p.addCurve(to: CGPoint(x: ax + 15, y: top),
                   control1: CGPoint(x: ax + 6.5, y: rect.minY),
                   control2: CGPoint(x: ax + 7.5, y: top))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top),
                 tangent2End: CGPoint(x: rect.maxX, y: top + radius), radius: radius)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY), radius: radius)
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius), radius: radius)
        p.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: top),
                 tangent2End: CGPoint(x: rect.minX + radius, y: top), radius: radius)
        p.closeSubpath()
        return p
    }
}

@MainActor
@Observable
final class PanelModel {
    var shown = false
    /// Arrow x inside the window (window coordinates).
    var arrowX: CGFloat = 200
    /// Whether the panel content (`MainMenuView` or `ClassicMainMenuView`) is
    /// mounted: only while the panel is on screen or animating closed. Left
    /// mounted while hidden, it kept re-rendering on every state change and
    /// every second for its relative timestamps.
    var contentMounted = false

    // Content state that has to survive the content being unmounted between
    // openings, so the panel reopens on the same tab and size.
    var selectedTab: MainMenuView.Tab = .usage
    var classicSelectedTab: ClassicMainMenuView.Tab = .usage
    // Measured heights driving the popover frame, written by whichever
    // content view is mounted. Defaults are reasonable fallbacks for the
    // first render pass, before the GeometryReader-based measurements fire.
    var usageContentHeight: CGFloat = 420
    var chromeHeight: CGFloat = 180

    /// Popover height is driven by measured Usage tab content + measured chrome.
    /// The Usage tab is chosen as the height reference because it's the
    /// content-heaviest tab; sizing for it gives other tabs enough headroom.
    /// Capped only by available screen space; no artificial floor — the popover
    /// matches its content exactly, so there is no padding gap inside the
    /// ScrollView when content is short.
    var popoverHeight: CGFloat {
        let screenCap: CGFloat = (NSScreen.main?.visibleFrame.height ?? 900) - 100
        let maxHeight: CGFloat = min(900, screenCap)

        // +1 for the Divider between content and footer (not measured).
        let desired = chromeHeight + usageContentHeight + 1

        return min(maxHeight, desired)
    }
}

private enum PanelMetrics {
    static let width: CGFloat = 360
    static let margin: CGFloat = 22
    static let arrow: CGFloat = 10
}

/// The panel chrome: arrow-notched shape, warm background, scale/fade in from the arrow.
struct PopoverRoot: View {
    @ObservedObject var appState: AppState
    @ObservedObject var config: MenuBarConfig
    var model: PanelModel
    var locale: Locale
    @AppStorage("panelStyle") private var style: PanelStyle = .default

    /// Active account's session utilization (0…1), used to warm the bloom.
    private var load: Double {
        guard let id = appState.activeAccount?.id,
              let u = appState.accountUsage[id]?.fiveHour?.utilization else { return 0 }
        return u / 100
    }

    var body: some View {
        // On macOS 26 the 1.x system popover had no arrow, so Classic has none
        // there; on earlier systems it did, so Classic keeps it.
        let arrow = style == .classic && ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 0 : PanelMetrics.arrow
        let shape = PopoverShape(arrowX: model.arrowX - PanelMetrics.margin, arrowHeight: arrow)
        VStack(spacing: 0) {
            Color.clear.frame(height: arrow)
            Group {
                if !model.contentMounted {
                    // Same size as the content, so `show()` can position the
                    // panel before the content has mounted.
                    Color.clear.frame(height: model.popoverHeight)
                } else if style == .classic {
                    // A fresh mount starts hidden; reveal it once it is in
                    // the hierarchy.
                    ClassicMainMenuView(panel: model)
                        .onAppear { model.shown = true }
                } else {
                    // Likewise, so the staggered entrance animates.
                    MainMenuView(panel: model)
                        .onAppear { model.shown = true }
                }
            }
            .environmentObject(appState)
            .environmentObject(config)
            .environment(\.locale, locale)
            .environment(\.panelStyle, style)
            .environment(\.panelShown, model.shown)
            .frame(width: PanelMetrics.width)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background {
            if style == .translucent || style == .classic {
                if #available(macOS 26.0, *) {
                    // Liquid Glass, as the system popover draws itself on
                    // macOS 26+: the desktop shows through.
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    VisualEffectBackground(material: .popover)
                        .clipShape(shape)
                }
            } else {
                PanelBackground(tint: UsageTint.at(load), intensity: 0.8 + load * 0.4, style: style)
                    .animation(Theme.gentle, value: load)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            }
        }
        .overlay(shape.stroke(Theme.hairline, lineWidth: 0.5))
        .clipShape(shape)
        // The system popover casts a shadow; Classic does too. It goes after
        // the clip, which would otherwise cut it off.
        .shadow(color: .black.opacity(style == .classic ? 0.25 : 0),
                radius: style == .classic ? 12 : 0, y: style == .classic ? 4 : 0)
        .padding(PanelMetrics.margin)
        // Classic appears and disappears at once, like the 1.x popover
        // (`NSPopover.animates = false`); the others scale in from the arrow.
        .scaleEffect(model.shown || style == .classic ? 1 : 0.95,
                     anchor: UnitPoint(x: model.arrowX / (PanelMetrics.width + PanelMetrics.margin * 2), y: 0))
        .opacity(model.shown ? 1 : 0)
        .animation(style == .classic ? nil
                   : model.shown ? .spring(duration: 0.36, bounce: 0.08) : .easeIn(duration: 0.14),
                   value: model.shown)
    }
}

/// Borderless, non-activating panel that floats under the menu bar.
final class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class FittingHostingView<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        Task { @MainActor [weak self] in self?.onResize?() }
    }
}

/// Shows / hides the floating panel anchored under a status item.
@MainActor
final class PopoverController {
    private let panel = FloatingPanel()
    private let model: PanelModel
    private let hosting: FittingHostingView<PopoverRoot>
    private weak var statusItem: NSStatusItem?
    private var globalMonitor: Any?
    private var lastSize: CGSize = .zero

    init(appState: AppState, config: MenuBarConfig, locale: Locale, statusItem: NSStatusItem) {
        let model = PanelModel()
        self.model = model
        self.statusItem = statusItem
        hosting = FittingHostingView(rootView: PopoverRoot(appState: appState, config: config, model: model, locale: locale))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        hosting.onResize = { [weak self] in self?.reposition(force: false) }
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.onCancel = { [weak self] in self?.hide() }
    }

    var isShown: Bool { model.shown }

    func updateRoot(appState: AppState, config: MenuBarConfig, locale: Locale) {
        hosting.rootView = PopoverRoot(appState: appState, config: config, model: model, locale: locale)
    }

    /// When a press on the status item itself closed the panel. That press
    /// closes it on mouse-down (the panel resigns key, or — with the menu bar
    /// drawn by another process — the outside-click monitor sees it), and the
    /// button's action follows on mouse-up: it must not reopen what this same
    /// click just closed, or a second click on the icon never closes the panel.
    private var closedByStatusItemPressAt: Date?

    func toggle() {
        if model.shown {
            hide()
            return
        }
        if let closedAt = closedByStatusItemPressAt, Date().timeIntervalSince(closedAt) < 1 {
            closedByStatusItemPressAt = nil
            return
        }
        show()
    }

    func show() {
        reposition(force: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        if model.contentMounted {
            // Reopened before the close finished: the content is still there.
            Task { @MainActor [weak self] in self?.model.shown = true }
        } else {
            // PopoverRoot sets `shown` once the content has mounted.
            model.contentMounted = true
        }
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Global monitors are delivered on the main thread.
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        guard model.shown else { return }
        closedByStatusItemPressAt = isPressingStatusItem() ? Date() : nil
        model.shown = false
        // Classic has no fade-out to wait for; leaving the now-invisible panel
        // up for 180 ms would swallow clicks meant for the window behind it.
        let style = UserDefaults.standard.string(forKey: "panelStyle").flatMap(PanelStyle.init(rawValue:)) ?? .default
        if style == .classic {
            panel.orderOut(nil)
            model.contentMounted = false
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
            self.model.contentMounted = false
        }
    }

    /// True while a mouse button is held down over the status item, anywhere
    /// in its slot of the menu bar. The button's own bounds stop short of the
    /// screen's top edge, and `contains` excludes a rect's max edge, so a
    /// click with the pointer pushed against the top of the screen (where
    /// menu bar clicks often land) didn't count and the panel reopened.
    private func isPressingStatusItem() -> Bool {
        guard NSEvent.pressedMouseButtons != 0,
              let slot = statusItem?.button?.window?.frame else { return false }
        let p = NSEvent.mouseLocation
        return p.x >= slot.minX && p.x <= slot.maxX && p.y >= slot.minY && p.y <= slot.maxY + 1
    }

    /// Anchor under the status item with the arrow pointing at it; keep the top edge fixed on resize.
    private func reposition(force: Bool) {
        guard let button = statusItem?.button, let bw = button.window else { return }
        let size = hosting.intrinsicContentSize.width > 0 ? hosting.intrinsicContentSize : hosting.fittingSize
        if !force, abs(size.width - lastSize.width) < 0.5, abs(size.height - lastSize.height) < 0.5 { return }
        lastSize = size
        let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bw.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let midX = b.midX
        var x = midX - size.width / 2
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        let top = b.minY - 3 + PanelMetrics.margin
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        let arrow = midX - x
        if abs(model.arrowX - arrow) > 0.5 { model.arrowX = arrow }
    }
}
