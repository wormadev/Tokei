import AppKit
import SwiftUI

/// Click: glass panel. Right-click: Refresh / Settings / Quit menu.
@MainActor
final class StatusBarController: NSObject {
    private let refresher: Refresher
    private let connector: Connector
    private let openSettings: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var shown: Shown?
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
        let display = UsageDisplay.current
        let rings = Self.ringValues(refresher.states, enabled: refresher.enabled)
        let lines = Self.menuLines(
            rings,
            weekly: UserDefaults.standard.bool(forKey: Prefs.menuBarWeeklyKey),
            session: UserDefaults.standard.bool(forKey: Prefs.menuBarSessionKey),
            display: display
        )
        let shown = Shown(rings: rings, lines: lines, display: display)
        guard shown != self.shown || item.button?.image == nil else { return }
        self.shown = shown
        item.button?.image = Self.statusImage(rings, lines: lines, display: display)
    }

    private struct Shown: Equatable {
        var rings: Rings
        var lines: [String]
        var display: UsageDisplay
    }

    /// Weekly above session, matching outer/inner ring. Unknown values are left out.
    nonisolated static func menuLines(_ rings: Rings, weekly: Bool, session: Bool, display: UsageDisplay) -> [String] {
        let both = weekly && session
        return [
            weekly ? rings.weekly.map { (both ? "W " : "") + display.text($0) } : nil,
            session ? rings.session.map { (both ? "5h " : "") + display.text($0) } : nil,
        ].compactMap(\.self)
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

    /// Rings plus an optional number column, drawn as one template image so it follows the
    /// menu bar's appearance. Outer ring = weekly, inner = 5h session; faint tracks keep the
    /// mark recognizable at 0%.
    static func statusImage(_ rings: Rings, lines: [String], display: UsageDisplay) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: lines.count > 1 ? 9 : 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textWidth = lines.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        let width = 18 + (lines.isEmpty ? 0 : 4 + ceil(textWidth))
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            for (radius, used) in [(7.0, rings.weekly), (3.6, rings.session)] {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 2.2
                NSColor.black.withAlphaComponent(0.3).setStroke()
                track.stroke()
                guard let used else { continue }
                let value = display.value(used)
                guard value > 0 else { continue }
                let sweep = min(value, 1) * 360
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = sweep >= 360 ? .butt : .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            let lineHeight = font.ascender - font.descender
            let top = 9 + lineHeight * CGFloat(lines.count) / 2
            for (index, line) in lines.enumerated() {
                let y = top - lineHeight * CGFloat(index + 1) - font.descender
                (line as NSString).draw(at: NSPoint(x: 22, y: y), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        let describe = { (used: Double?) in used.map(display.text) ?? "unknown" }
        let mode = display == .used ? "used" : "left"
        image.accessibilityDescription = "Tokei: session \(describe(rings.session)) \(mode), weekly \(describe(rings.weekly)) \(mode)"
        return image
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
