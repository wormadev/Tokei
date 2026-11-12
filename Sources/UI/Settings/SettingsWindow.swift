import SwiftUI

@MainActor
final class SettingsWindowController {
    private let refresher: Refresher
    private let connector: Connector
    private var window: NSWindow?

    init(refresher: Refresher, connector: Connector) {
        self.refresher = refresher
        self.connector = connector
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(refresher: refresher, connector: connector))
            // Height follows the user; width is fixed by the two columns.
            host.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Tokei Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: SettingsView.width, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            // After center(): restores the last size and place, if any.
            window.setFrameAutosaveName("Settings")
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate()
        // Accessory apps can be refused activation (cooperative activation); still come to front.
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}

/// Settings on the left, the real panel on the right, so every change shows as it will look.
struct SettingsView: View {
    let refresher: Refresher
    let connector: Connector

    static let formWidth: CGFloat = 380
    static let stageWidth: CGFloat = 400
    static let width = formWidth + 1 + stageWidth

    var body: some View {
        HStack(spacing: 0) {
            SettingsForm(refresher: refresher).frame(width: Self.formWidth)
            Divider()
            VStack(spacing: 0) {
                PanelPreview(refresher: refresher, connector: connector)
                Divider()
                SettingsFooter()
            }
            .frame(width: Self.stageWidth)
        }
        .frame(width: Self.width)
        .frame(minHeight: 480, maxHeight: .infinity)
    }
}

private struct SettingsFooter: View {
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    var body: some View {
        HStack(spacing: 12) {
            Text("Tokei \(Self.version) (\(Self.build))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Link("Website", destination: URL(string: "https://tokei.worma.dev")!)
            if Updater.shared.isConfigured {
                Button("Check for Updates") { Updater.shared.checkForUpdates() }
            }
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .frame(height: 44)
    }
}
