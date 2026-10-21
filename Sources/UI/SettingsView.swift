import ServiceManagement
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(refresher: refresher, connector: connector)))
            window.title = "Tokei Settings"
            // Full-size content lets the glass sidebar run under the titlebar, like System Settings.
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        // Accessory apps can be refused activation (cooperative activation); still come to front.
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}

struct SettingsView: View {
    let refresher: Refresher
    let connector: Connector
    /// "general", "display" or a provider's raw value.
    @AppStorage("settingsTab") private var page = "general"
    @State private var order = Prefs.providerOrder

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { page = $0 ?? "general" })) {
                Label("General", systemImage: "gearshape").tag("general")
                Label("Display", systemImage: "eye").tag("display")
                Section("Providers") {
                    ForEach(order) { id in
                        ProviderSidebarRow(id: id, state: refresher.states[id], installed: refresher.installed.contains(id)).tag(id.rawValue)
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        Prefs.providerOrder = order
                    }
                }
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(title)
        }
        .frame(width: 640, height: 420)
    }

    private var title: String {
        switch page {
        case "general": "General"
        case "display": "Display"
        default: ProviderID(rawValue: page)?.name ?? "General"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case "display": DisplaySettings(refresher: refresher)
        default:
            if let id = ProviderID(rawValue: page) {
                ProviderPage(id: id, refresher: refresher, connector: connector).id(id)
            } else {
                GeneralSettings(installed: refresher.installed)
            }
        }
    }
}

/// Name plus a status dot: green working, orange needs attention, none when off.
/// Not installed: grayed out.
private struct ProviderSidebarRow: View {
    let id: ProviderID
    let state: ProviderState?
    let installed: Bool
    @AppStorage private var enabled: Bool

    init(id: ProviderID, state: ProviderState?, installed: Bool) {
        self.id = id
        self.state = state
        self.installed = installed
        _enabled = AppStorage(wrappedValue: true, Prefs.enabledKey(id))
    }

    var body: some View {
        HStack {
            Text(id.name).foregroundStyle(!installed ? .tertiary : enabled ? .primary : .secondary)
            Spacer()
            if installed, enabled {
                Circle()
                    .fill(state?.error == nil && state?.snapshot != nil ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

private struct GeneralSettings: View {
    let installed: Set<ProviderID>
    @AppStorage(Prefs.refreshIntervalKey) private var interval = 300
    @AppStorage(Prefs.refreshOnOpenKey) private var refreshOnOpen = true
    @AppStorage(Prefs.menuBarStyleKey) private var menuBarStyle = MenuBarStyle.highest.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    /// Providers that aren't installed can't feed the menu bar.
    private var menuBarStyles: [MenuBarStyle] {
        MenuBarStyle.all.filter { style in
            if case let .provider(id) = style { return installed.contains(id) }
            return true
        }
    }

    private var refreshFooter: String {
        switch (interval < 0, refreshOnOpen) {
        case (true, true): "Usage updates only when you open the panel (if older than a minute)."
        case (true, false): "Usage updates only when you press Refresh (⌘R)."
        case (false, true): "Opening the panel also refreshes anything older than a minute. Background refresh pauses while the Mac sleeps or is locked."
        case (false, false): "Background refresh pauses while the Mac sleeps or is locked."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Refresh in background", selection: $interval) {
                    ForEach([60, 120, 300, 600, 900, 1800], id: \.self) { Text("Every \($0 / 60) min").tag($0) }
                    Divider()
                    ForEach([3600, 7200, 14400], id: \.self) { Text("Every \($0 / 3600) h").tag($0) }
                    Divider()
                    Text("Never").tag(-1)
                }
                Toggle("Refresh when opening the panel", isOn: $refreshOnOpen)
            } footer: {
                Text(refreshFooter)
            }
            Section {
                Picker("Menu bar", selection: $menuBarStyle) {
                    ForEach(menuBarStyles) { style in
                        Text(style.label).tag(style.rawValue)
                        if style == .highest { Divider() }
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplaySettings: View {
    let refresher: Refresher
    @AppStorage(Prefs.showAccountKey) private var showAccount = true
    @AppStorage(Prefs.showDetailsKey) private var showDetails = false
    @AppStorage(Prefs.showModelLimitsKey) private var showModelLimits = false
    @AppStorage(Prefs.showHistoryKey) private var showHistory = false
    @AppStorage(Prefs.absoluteResetsKey) private var absoluteResets = false

    private var snapshots: [Snapshot] {
        refresher.enabled.compactMap { refresher.states[$0]?.snapshot }
    }

    private var historyReady: Bool {
        refresher.enabled.contains { id in refresher.history.series.contains { $0.key.hasPrefix("\(id.rawValue)/") && $0.value.count > 1 } }
    }

    var body: some View {
        Form {
            Section("Always shown: session and weekly limits") {
                Toggle("Account and plan", isOn: $showAccount)
                toggle("Spend, credits and breakdown", isOn: $showDetails, available: snapshots.contains { !$0.details.isEmpty },
                       note: "None of your providers report spend or credits right now.")
                toggle("Per-model limits", isOn: $showModelLimits, available: snapshots.contains { $0.windows.contains { $0.kind == .secondary } },
                       note: "None of your providers report per-model limits right now.")
                toggle("Usage history (7 days)", isOn: $showHistory, available: historyReady,
                       note: "Builds up as Tokei runs: one point per limit every 15 minutes.")
            }
            Section {
                Toggle("Show reset as clock time", isOn: $absoluteResets)
            } footer: {
                Text(absoluteResets ? "Example: Resets Tue 14:00" : "Example: Resets in 2h 13m")
            }
        }
        .formStyle(.grouped)
    }

    /// A toggle whose data may not exist yet says so, instead of silently doing nothing.
    private func toggle(_ title: String, isOn: Binding<Bool>, available: Bool, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            if !available {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProviderPage: View {
    let id: ProviderID
    let refresher: Refresher
    let connector: Connector
    @AppStorage private var enabled: Bool

    init(id: ProviderID, refresher: Refresher, connector: Connector) {
        self.id = id
        self.refresher = refresher
        self.connector = connector
        _enabled = AppStorage(wrappedValue: true, Prefs.enabledKey(id))
    }

    private var installed: Bool { refresher.installed.contains(id) }

    var body: some View {
        Form {
            if !installed {
                Section {
                    Label("Not installed on this Mac", systemImage: "xmark.circle").foregroundStyle(.secondary)
                } footer: {
                    Text(LocalizedStringKey(installHint))
                }
            }
            Section {
                Toggle("Show in panel", isOn: $enabled)
                    .disabled(!installed)
                    .onChange(of: enabled) { _, on in
                        if on { Task { await refresher.refresh(id) } }
                    }
            } footer: {
                Text("Drag providers in the sidebar to change their order in the panel.")
            }
            if installed, enabled {
                Section("Status") {
                    status
                    if let plan = refresher.states[id]?.snapshot?.account.plan {
                        LabeledContent("Plan", value: plan)
                    }
                }
                Section("Source") { source }
            }
        }
        .formStyle(.grouped)
    }

    private var installHint: String {
        switch id {
        case .claude: "Install Claude Code and sign in with `claude`. Tokei picks it up within a minute."
        case .codex: "Install the Codex CLI (`brew install --cask codex`) and run `codex login`. Tokei picks it up within a minute."
        }
    }

    @ViewBuilder
    private var status: some View {
        let state = refresher.states[id]
        if let error = connector.errors[id] ?? state?.error {
            Label(LocalizedStringKey(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if let user = state?.snapshot?.account.user {
            Label("Connected as \(user)", systemImage: "checkmark.circle")
        } else if state?.snapshot != nil {
            Label("Connected", systemImage: "checkmark.circle")
        } else {
            Label("Not checked yet", systemImage: "clock").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var source: some View {
        switch id {
        case .claude:
            caption("Reads Claude Code's sign-in from the Keychain. Connect from the Tokei panel.")
        case .codex:
            caption("Reads \(CodexProvider.authFile.path(percentEncoded: false)) from the Codex CLI.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
