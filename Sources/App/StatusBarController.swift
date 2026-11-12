import AppKit
import SwiftUI

/// Click: glass panel. Right-click: Refresh / Settings / Quit menu. One status item, or one
/// per provider when the menu bar is set to show each.
@MainActor
final class StatusBarController: NSObject {
    private let refresher: Refresher
    private let connector: Connector
    private let openSettings: () -> Void
    /// Key: provider raw value, or "main" for the single item.
    private var items: [String: NSStatusItem] = [:]
    private var shown: [String: MenuBarIcon] = [:]
    /// The item the panel hangs from.
    private weak var anchor: NSStatusBarButton?
    private let layout = PanelLayout()
    private lazy var panel: Panel = {
        let panel = Panel(rootView: PanelView(
            refresher: refresher,
            connector: connector,
            layout: layout,
            openSettings: { [weak self] in
                self?.panel.hide()
                self?.openSettings()
            },
            // The panel floats above Sparkle's window.
            checkForUpdates: { [weak self] in
                self?.panel.hide()
                Updater.shared.checkForUpdates()
            }
        ))
        panel.isStatusItemClick = { [weak self] point in
            self?.items.values.contains { Self.frame(of: $0.button)?.contains(point) == true } ?? false
        }
        return panel
    }()

    init(refresher: Refresher, connector: Connector, openSettings: @escaping () -> Void) {
        self.refresher = refresher
        self.connector = connector
        self.openSettings = openSettings
        super.init()
        update()
        observe()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // Reset times pass without any state change.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private static func frame(of button: NSStatusBarButton?) -> NSRect? {
        guard let button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func makeItem(_ key: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Keeps each item's spot after the user drags it with ⌘.
        item.autosaveName = "tokei.\(key)"
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        return item
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let item = items.values.first(where: { $0.button === sender }) else { return }
            let menu = NSMenu()
            menu.addItem(withTitle: "Refresh", action: #selector(refreshAll), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            if Updater.shared.isConfigured {
                let title = Updater.shared.availableVersion.map { "Update to \($0)…" } ?? "Check for Updates…"
                menu.addItem(withTitle: title, action: #selector(checkForUpdates), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Tokei", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if panel.isVisible, anchor === sender {
            panel.hide()
        } else {
            showPanel(below: sender)
        }
    }

    func togglePanel() {
        if panel.isVisible { panel.hide() } else { showPanel() }
    }

    func showPanel(below button: NSStatusBarButton? = nil) {
        if Prefs.refreshOnOpen { refresher.refreshOnOpen() }
        let firstItem = (refresher.enabled.map(\.rawValue) + ["main"]).lazy.compactMap { self.items[$0]?.button }.first
        anchor = button ?? anchor ?? firstItem
        if let screen = anchor?.window?.screen ?? NSScreen.main { layout.maxHeight = screen.visibleFrame.height - 80 }
        panel.show(below: anchor)
    }

    @objc private func refreshAll() { refresher.refreshAll() }
    @objc private func showSettings() { openSettings() }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    private func observe() {
        withObservationTracking {
            _ = refresher.states
            _ = refresher.installed
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    /// Creating an item can post a defaults change, which calls back in here.
    private var updating = false

    private func update() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        let config = MenuBarConfig.current
        let enabled = refresher.enabled
        let wanted: [(key: String, provider: ProviderID?)] = config.each && !enabled.isEmpty
            ? enabled.map { ($0.rawValue, $0) }
            : [("main", nil)]
        for key in items.keys where !wanted.contains(where: { $0.key == key }) {
            if let item = items.removeValue(forKey: key) { NSStatusBar.system.removeStatusItem(item) }
            shown[key] = nil
        }
        // Reversed: each new item lands left of the last, so panel order reads left to right.
        for (key, provider) in wanted.reversed() {
            let item = items[key] ?? makeItem(key)
            items[key] = item
            var itemConfig = config
            if let provider { itemConfig.provider = provider }
            let icon = MenuBarIcon.make(states: refresher.states, enabled: enabled, config: itemConfig, display: .current)
            guard icon != shown[key] || item.button?.image == nil else { continue }
            shown[key] = icon
            item.button?.image = icon.image()
        }
    }
}

/// Borderless panel under the status item; the SwiftUI root is the single Liquid Glass surface.
@MainActor
final class Panel: NSPanel {
    var isStatusItemClick: ((NSPoint) -> Bool)?
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
                if self.isStatusItemClick?(NSEvent.mouseLocation) == true { return }
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
    override func performClose(_ sender: Any?) { hide() }

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
        let y = max(top - size.height, visible.minY + 8)
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }
}

/// Clicks act immediately even before the non-activating panel becomes key, like a menu.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
