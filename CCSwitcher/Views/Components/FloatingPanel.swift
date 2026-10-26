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

    /// Active account's session utilization (0…1), used to warm the bloom.
    private var load: Double {
        guard let id = appState.activeAccount?.id,
              let u = appState.accountUsage[id]?.fiveHour?.utilization else { return 0 }
        return u / 100
    }

    var body: some View {
        let shape = PopoverShape(arrowX: model.arrowX - PanelMetrics.margin, arrowHeight: PanelMetrics.arrow)
        VStack(spacing: 0) {
            Color.clear.frame(height: PanelMetrics.arrow)
            MainMenuView()
                .environmentObject(appState)
                .environmentObject(config)
                .environment(\.locale, locale)
                .environment(\.panelShown, model.shown)
                .frame(width: PanelMetrics.width)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(
            PanelBackground(tint: UsageTint.at(load), intensity: 0.8 + load * 0.4)
                .animation(Theme.gentle, value: load)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        )
        .overlay(shape.stroke(Theme.hairline, lineWidth: 0.5))
        .clipShape(shape)
        .padding(PanelMetrics.margin)
        .scaleEffect(model.shown ? 1 : 0.95,
                     anchor: UnitPoint(x: model.arrowX / (PanelMetrics.width + PanelMetrics.margin * 2), y: 0))
        .opacity(model.shown ? 1 : 0)
        .animation(model.shown ? .spring(duration: 0.36, bounce: 0.08) : .easeIn(duration: 0.14),
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
        Task { @MainActor [weak self] in self?.model.shown = true }
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    /// True while a mouse button is held down over the status item.
    private func isPressingStatusItem() -> Bool {
        guard NSEvent.pressedMouseButtons != 0,
              let button = statusItem?.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
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
