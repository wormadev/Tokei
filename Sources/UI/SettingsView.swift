import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let refresher: Refresher
    private var window: NSWindow?

    init(refresher: Refresher) {
        self.refresher = refresher
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(refresher: refresher)))
            window.title = "Quota Settings"
            window.styleMask = [.titled, .closable]
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
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Providers", systemImage: "square.stack.3d.up", value: "providers") { ProviderSettings(refresher: refresher) }
            Tab("Display", systemImage: "eye", value: "display") { DisplaySettings() }
        }
        .frame(width: 480, height: 460)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.refreshIntervalKey) private var interval = 300
    @AppStorage(Prefs.menuBarStyleKey) private var menuBarStyle = MenuBarStyle.highest.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Refresh every", selection: $interval) {
                ForEach([60, 120, 300, 600, 900, 1800], id: \.self) { seconds in
                    Text("\(seconds / 60) min").tag(seconds)
                }
            }
            Text("Opening the panel also refreshes anything older than a minute. Refresh pauses while the Mac sleeps or is locked.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Menu bar", selection: $menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0.rawValue) }
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
        .formStyle(.grouped)
    }
}

private struct DisplaySettings: View {
    @AppStorage(Prefs.showAccountKey) private var showAccount = true
    @AppStorage(Prefs.showDetailsKey) private var showDetails = false
    @AppStorage(Prefs.showModelLimitsKey) private var showModelLimits = false
    @AppStorage(Prefs.showHistoryKey) private var showHistory = false
    @AppStorage(Prefs.absoluteResetsKey) private var absoluteResets = false

    var body: some View {
        Form {
            Section("Always shown: session and weekly limits") {
                Toggle("Account and plan", isOn: $showAccount)
                Toggle("Spend and credits", isOn: $showDetails)
                Toggle("Per-model limits", isOn: $showModelLimits)
                Toggle("Usage history (7 days)", isOn: $showHistory)
            }
            Section {
                Toggle("Show reset as clock time", isOn: $absoluteResets)
            } footer: {
                Text(absoluteResets ? "Example: Resets Tue 14:00" : "Example: Resets in 2h 13m")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSettings: View {
    let refresher: Refresher

    var body: some View {
        Form {
            ForEach(ProviderID.allCases) { id in
                ProviderRow(id: id, refresher: refresher)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderRow: View {
    let id: ProviderID
    let refresher: Refresher
    @AppStorage private var enabled: Bool
    @State private var copilotCode: CopilotDeviceFlow.Code?
    @State private var actionError: String?
    @State private var copilotSignedIn = CopilotProvider.token != nil
    @State private var signIn: Task<Void, Never>?

    init(id: ProviderID, refresher: Refresher) {
        self.id = id
        self.refresher = refresher
        _enabled = AppStorage(wrappedValue: true, Prefs.enabledKey(id))
    }

    var body: some View {
        Section {
            Toggle(id.name, isOn: $enabled)
                .font(.headline)
                .onChange(of: enabled) { _, on in
                    if on { Task { await refresher.refresh(id) } }
                }
            if enabled {
                status
                action
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let state = refresher.states[id]
        if let error = actionError ?? state?.error {
            Label(LocalizedStringKey(error), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        } else if let user = state?.snapshot?.account.user {
            Label("Connected as \(user)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        } else if state?.snapshot != nil {
            Label("Connected", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch id {
        case .claude:
            HStack {
                Text("Reads Claude Code's sign-in. Choose Always Allow so background refreshes stay silent.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Connect") {
                    if ClaudeProvider.loadCredentials(allowUI: true) != nil {
                        UserDefaults.standard.set(true, forKey: ClaudeProvider.keychainConnectedKey)
                        actionError = nil
                        Task { await refresher.refresh(.claude) }
                    } else {
                        actionError = "No Claude Code sign-in found. Run `claude` and sign in."
                    }
                }
            }
        case .codex:
            source("Reads \(CodexProvider.authFile.path(percentEncoded: false)) from the Codex CLI.")
        case .cursor:
            source("Reads Cursor's local sign-in. Keep the Cursor app signed in.")
        case .gemini:
            source("Reads ~/.gemini/oauth_creds.json from the Gemini CLI. Google ended CLI quotas for some personal plans in June 2026.")
        case .copilot:
            copilot
        }
    }

    private func source(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var copilot: some View {
        if let code = copilotCode {
            HStack {
                Text("Enter code **\(code.user_code)** on GitHub (copied).").font(.callout)
                Spacer()
                ProgressView().controlSize(.small)
                Button("Cancel") {
                    signIn?.cancel()
                    copilotCode = nil
                }
            }
        } else if copilotSignedIn {
            HStack {
                source("Signed in with GitHub.")
                Spacer()
                Button("Sign Out") {
                    CopilotDeviceFlow.signOut()
                    copilotSignedIn = false
                }
            }
        } else {
            HStack {
                source("Sign in with GitHub to read your Copilot quota.")
                Spacer()
                Button("Sign In…", action: signInCopilot)
            }
        }
    }

    private func signInCopilot() {
        signIn = Task {
            do {
                let code = try await CopilotDeviceFlow.start()
                copilotCode = code
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.user_code, forType: .string)
                if let url = URL(string: code.verification_uri) { NSWorkspace.shared.open(url) }
                try await CopilotDeviceFlow.complete(code)
                copilotCode = nil
                copilotSignedIn = true
                actionError = nil
                await refresher.refresh(.copilot)
            } catch is CancellationError {
                return
            } catch {
                copilotCode = nil
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
