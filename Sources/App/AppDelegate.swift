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
    private var statusBar: StatusBarController!
    private lazy var settings = SettingsWindowController(refresher: refresher)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests use the app as host: no status item, no live fetches, no Keychain.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        Prefs.registerDefaults()
        Prefs.detectProvidersOnce()
        refresher = Refresher(providers: [
            ClaudeProvider(), CodexProvider(), CursorProvider(), GeminiProvider(), CopilotProvider(),
        ])
        statusBar = StatusBarController(refresher: refresher, openSettings: { [weak self] in self?.settings.show() })
        refresher.start()
        #if DEBUG
        // `-debugShowPanel YES` / `-debugShowSettings YES`: open UI at launch for screenshots.
        // The status item has no screen frame until the menu bar lays it out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            if UserDefaults.standard.bool(forKey: "debugShowPanel") { statusBar.showPanel() }
            if UserDefaults.standard.bool(forKey: "debugShowSettings") { settings.show() }
        }
        #endif
    }
}
