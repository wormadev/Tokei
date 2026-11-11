import AppKit
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
        refresher.onSignInExpired = { [connector] id, hint in
            guard UserDefaults.standard.bool(forKey: Prefs.renewSignInKey), let connector else {
                return Notifier.postSignInExpired(id, hint: hint)
            }
            Task {
                if await !connector.renewSignIn(id) { Notifier.postSignInExpired(id, hint: hint) }
            }
        }
        statusBar = StatusBarController(refresher: refresher, connector: connector, openSettings: { [weak self] in self?.settings.show() })
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
