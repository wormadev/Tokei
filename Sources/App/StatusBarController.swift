import AppKit
import SwiftUI

/// Click: glass panel. Right-click: Refresh / Settings / Quit menu.
@MainActor
final class StatusBarController: NSObject {
    private let refresher: Refresher
    private let connector: Connector
    private let openSettings: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var shownRings: Rings?
    private lazy var panel: Panel = {
        let panel = Panel(rootView: PanelView(
            refresher: refresher,
            connector: connector,
            openSettings: { [weak self] in
                self?.panel.hide()
                self?.openSettings()
            }
        ))
        panel.statusItemFrame = { [weak self] in self?.itemFrame }
        return panel
    }()

    init(refresher: Refresher, connector: Connector, openSettings: @escaping () -> Void) {
        self.refresher = refresher
        self.connector = connector
        self.openSettings = openSettings
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        update()
        observe()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private var itemFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "Refresh", action: #selector(refreshAll), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Tokei", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if panel.isVisible {
            panel.hide()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        if Prefs.refreshOnOpen { refresher.refreshStale() }
        panel.show(below: item.button)
    }

    @objc private func refreshAll() { refresher.refreshAll() }
    @objc private func showSettings() { openSettings() }

    private func observe() {
        withObservationTracking {
            _ = refresher.states
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        let rings = Self.ringValues(refresher.states, enabled: refresher.enabled)
        if rings != shownRings || item.button?.image == nil {
            shownRings = rings
            item.button?.image = Self.ringsImage(rings)
        }
        let style = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: Prefs.menuBarStyleKey))
        let usage = style.sources(enabled: refresher.enabled).flatMap { Self.highestUsage(refresher.states, enabled: $0) }
        let title = usage.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
        if item.button?.title != title {
            item.button?.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
            )
        }
    }

    struct Rings: Equatable {
        /// 0...1 or nil when unknown; drawn as track only.
        var session: Double?
        var weekly: Double?
    }

    /// Session and weekly usage of the first provider in panel order: the one the rings show.
    nonisolated static func ringValues(_ states: [ProviderID: ProviderState], enabled: [ProviderID]) -> Rings {
        let primary = enabled.first.flatMap { states[$0]?.snapshot }?.windows.filter { $0.kind == .primary } ?? []
        // Codex labels windows by length; when lengths are missing they fall back to slot order.
        let session = primary.first { $0.id == "session" } ?? primary.first { $0.id != "weekly" }
        let weekly = primary.first { $0.id == "weekly" } ?? primary.first { $0.id != session?.id }
        return Rings(session: session?.used, weekly: weekly?.used)
    }

    /// The app icon's two rings as a template image: outer = weekly, inner = 5h session.
    /// A faint full track keeps the mark recognizable at 0%.
    static func ringsImage(_ rings: Rings) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            for (radius, value) in [(7.0, rings.weekly), (3.6, rings.session)] {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 2.2
                NSColor.black.withAlphaComponent(0.3).setStroke()
                track.stroke()
                guard let value, value > 0 else { continue }
                let sweep = min(value, 1) * 360
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = sweep >= 360 ? .butt : .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        let percent = { (value: Double?) in value.map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown" }
        image.accessibilityDescription = "Tokei: session \(percent(rings.session)), weekly \(percent(rings.weekly))"
        return image
    }

    /// The most constrained primary window across the given providers: what limits you first.
    nonisolated static func highestUsage(_ states: [ProviderID: ProviderState], enabled: [ProviderID]) -> Double? {
        enabled.compactMap { states[$0]?.snapshot }
            .flatMap(\.windows)
            .filter { $0.kind == .primary }
            .map(\.used)
            .max()
    }
}

/// Borderless panel under the status item; the SwiftUI root is the single Liquid Glass surface.
@MainActor
final class Panel: NSPanel {
    var statusItemFrame: (() -> NSRect?)?
    private var topEdge: CGFloat?
    private var anchorMidX: CGFloat?
    /// The status item's screen, not the panel's last one: they differ across displays.
    private var anchorScreen: NSScreen?
    private var outsideClickMonitor: Any?

    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = rootView
            .glassEffect(.regular, in: .rect(cornerRadius: Design.panelRadius))
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { [weak self] size in
                // Resizing inside SwiftUI's layout pass recurses in AutoLayout; apply it next turn.
                DispatchQueue.main.async { self?.fit(size) }
            }
        let host = FirstMouseHostingView(rootView: content)
        // Without clipping, the window shadow traces the square frame behind the rounded glass.
        host.wantsLayer = true
        host.layer?.cornerRadius = Design.panelRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    func show(below button: NSStatusBarButton?) {
        if let button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            anchorMidX = rect.midX
            anchorScreen = window.screen
            topEdge = rect.minY - 6
            place(frame.size)
        }
        makeKeyAndOrderFront(nil)
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Status item clicks reach the global monitor too; the toggle handles those.
                if let item = self.statusItemFrame?(), item.contains(NSEvent.mouseLocation) { return }
                self.hide()
            }
        }
    }

    func hide() {
        orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    override func cancelOperation(_ sender: Any?) { hide() }

    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        place(size)
    }

    /// Centered under the status item, kept on screen, growing downward.
    private func place(_ size: CGSize) {
        let top = topEdge ?? frame.maxY
        let visible = (anchorScreen ?? screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = (anchorMidX ?? frame.midX) - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }
}

/// Clicks act immediately even before the non-activating panel becomes key, like a menu.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
