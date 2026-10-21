import AppKit
import SwiftUI

/// Click: glass panel. Right-click: Refresh / Settings / Quit menu.
@MainActor
final class StatusBarController: NSObject {
    private let refresher: Refresher
    private let openSettings: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel: Panel = {
        let panel = Panel(rootView: PanelView(
            refresher: refresher,
            openSettings: { [weak self] in
                self?.panel.hide()
                self?.openSettings()
            }
        ))
        panel.statusItemFrame = { [weak self] in self?.itemFrame }
        return panel
    }()

    init(refresher: Refresher, openSettings: @escaping () -> Void) {
        self.refresher = refresher
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
            menu.addItem(withTitle: "Quit Quota", action: #selector(NSApplication.terminate), keyEquivalent: "q")
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
        refresher.refreshStale()
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
        let highest = Self.highestUsage(refresher.states, enabled: refresher.enabled)
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Quota")
        image?.isTemplate = true
        item.button?.image = image
        let style = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: Prefs.menuBarStyleKey) ?? "") ?? .highest
        let title = style == .highest ? highest.map { " \(Int(($0 * 100).rounded()))%" } ?? "" : ""
        if item.button?.title != title {
            item.button?.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
            )
        }
    }

    /// The most constrained primary window across enabled providers: what limits you first.
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
            topEdge = rect.minY - 6
            place(frame.size)
        }
        makeKeyAndOrderFront(nil)
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
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
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
