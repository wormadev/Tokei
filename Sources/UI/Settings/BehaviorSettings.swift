import ServiceManagement
import SwiftUI

struct RefreshSettings: View {
    @AppStorage(Prefs.refreshIntervalKey) private var interval = Prefs.agentAwareInterval
    @AppStorage(Prefs.refreshOnOpenKey) private var refreshOnOpen = true

    private var explanation: String {
        let background = switch interval {
        case Prefs.agentAwareInterval: "Every 5 minutes while Claude Code or Codex is working, every 15 minutes when idle."
        case Prefs.neverInterval: refreshOnOpen ? "Usage updates only when you open the panel (if older than 2 minutes)." : "Usage updates only when you press Refresh (⌘R)."
        default: refreshOnOpen ? "Opening the panel also refreshes anything older than 2 minutes." : ""
        }
        return [background, interval == Prefs.neverInterval ? "" : "Pauses while the Mac sleeps or is locked."]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        Picker("Refresh in background", selection: $interval) {
            Text("Agent aware").tag(Prefs.agentAwareInterval)
            Divider()
            ForEach([60, 120, 300, 600, 900, 1800], id: \.self) { Text("Every \($0 / 60) min").tag($0) }
            Divider()
            ForEach([3600, 7200, 14400], id: \.self) { Text("Every \($0 / 3600) h").tag($0) }
            Divider()
            Text("Never").tag(Prefs.neverInterval)
        }
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Refresh when opening the panel", isOn: $refreshOnOpen)
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AlertSettings: View {
    @AppStorage(Prefs.notifyResetsKey) private var notifyResets = true
    @AppStorage(Prefs.notifySignInKey) private var notifySignIn = true
    @AppStorage(Prefs.renewSignInKey) private var renewSignIn = false

    var body: some View {
        Toggle("Notify when a limit resets", isOn: $notifyResets)
            .onChange(of: notifyResets) { _, on in
                if on { Notifier.requestPermissionIfEnabled() }
            }
        Toggle("Notify when a sign-in expires", isOn: $notifySignIn)
            .onChange(of: notifySignIn) { _, on in
                if on { Notifier.requestPermissionIfEnabled() }
            }
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Renew expired sign-ins", isOn: $renewSignIn)
            Text("Runs `claude auth status` or `codex login status` when a sign-in expires. That often lets the CLI renew its own token. You're notified only if it doesn't.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LoginAndUpdateSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var revertingLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            if loginStatus == .requiresApproval {
                Text("Allow Tokei in System Settings > General > Login Items.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if Updater.shared.isConfigured {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { Updater.shared.checksAutomatically },
                set: { Updater.shared.setChecksAutomatically($0) }))
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Share anonymous install count", isOn: Binding(
                    get: { Updater.shared.sharesInstallCount },
                    set: { Updater.shared.setSharesInstallCount($0) }))
                Text("Sends a random ID and Sparkle's anonymous system profile with update checks, to count how many people use Tokei. Only the ID, app and macOS versions and CPU type are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Updates are off in this build.").foregroundStyle(.secondary)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        // Putting the toggle back after a failure must not run the opposite call.
        if revertingLogin {
            revertingLogin = false
            return
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            let enabled = SMAppService.mainApp.status == .enabled
            if enabled != on {
                revertingLogin = true
                launchAtLogin = enabled
            }
        }
        loginStatus = SMAppService.mainApp.status
    }
}
