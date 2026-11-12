import AppKit
import UserNotifications
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var refresher: Refresher!
    private var connector: Connector!
    private var statusBar: StatusBarController!
    private var hotKey: HotKey?
    private var reminders: Reminders?
    private lazy var settings = SettingsWindowController(refresher: refresher, connector: connector)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests use the app as host: no status item, no live fetches, no Keychain.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        Prefs.registerDefaults()
        NSApp.mainMenu = Self.mainMenu()
        refresher = Refresher(providers: [
            ClaudeProvider(), CodexProvider(),
        ])
        refresher.onReset = { Notifier.postReset($0, $1) }
        Notifier.requestPermissionIfEnabled()
        connector = Connector(refresher: refresher)
        refresher.onRunningLow = { Notifier.postRunningLow($0, $1, threshold: $2) }
        UNUserNotificationCenter.current().delegate = self
        // Only a server rejection notifies; a token that merely passed its expiry renews silently.
        refresher.onSignInExpired = { [connector] id, _, rejected in
            guard UserDefaults.standard.bool(forKey: Prefs.renewSignInKey), let connector else {
                if rejected { Notifier.postSignInExpired(id) }
                return
            }
            Task {
                if await !connector.renewSignIn(id, userInitiated: false), rejected { Notifier.postSignInExpired(id) }
            }
        }
        statusBar = StatusBarController(refresher: refresher, connector: connector, openSettings: { [weak self] in self?.settings.show() })
        hotKey = HotKey { [weak self] in self?.statusBar.togglePanel() }
        reminders = Reminders(refresher: refresher, post: Notifier.postReminder)
        refresher.start()
        Updater.shared.start()
        #if DEBUG
        // `-debugShowPanel YES` / `-debugShowSettings YES`: open UI at launch for screenshots.
        // The status item has no screen frame until the menu bar lays it out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            if UserDefaults.standard.bool(forKey: "debugShowPanel") { statusBar.showPanel() }
            if UserDefaults.standard.bool(forKey: "debugShowSettings") { settings.show() }
        }
        #endif
    }

    /// Never shown (accessory app), but its key equivalents are what make ⌘W, ⌘Q and ⌘C work in Settings.
    private static func mainMenu() -> NSMenu {
        let app = NSMenu(title: "Tokei")
        app.addItem(withTitle: "Quit Tokei", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let main = NSMenu()
        for menu in [app, edit, window] {
            main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        return main
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Every notification is about something in the panel, so a click opens it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { statusBar?.showPanel() }
    }

    /// An accessory app counts as frontmost while its panel is open; show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
