import ServiceManagement
import SwiftUI

struct RefreshSettings: View {
    @AppStorage(Prefs.refreshIntervalKey) private var interval = Prefs.agentAwareInterval
    @AppStorage(Prefs.refreshOnOpenKey) private var refreshOnOpen = true

    private var explanation: String {
        let background = switch interval {
        case Prefs.agentAwareInterval: "Every 5 minutes while Claude Code or Codex is working, every 15 minutes when idle."
        case Prefs.neverInterval: refreshOnOpen ? "Usage updates only when you open the panel." : "Usage updates only when you press Refresh (⌘R)."
        default: ""
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
    @AppStorage(Prefs.notifyLowKey) private var notifyLow = true
    @AppStorage(Prefs.notifyUnusedKey) private var notifyUnused = false
    @AppStorage(Prefs.notifyBankedKey) private var notifyBanked = true
    @AppStorage(Prefs.renewSignInKey) private var renewSignIn = false

    var body: some View {
        notify("Notify when a limit runs low", $notifyLow)
            .help("At 80% and 95% used, when used up, and when the pace says it runs out before the reset")
        notify("Notify when a limit resets", $notifyResets)
        notify("Notify when unused weekly quota is about to reset", $notifyUnused)
            .help("A day and an hour before, when a quarter or more is left")
        notify("Notify when a banked reset is about to expire", $notifyBanked)
        notify("Notify when a sign-in expires", $notifySignIn)
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Renew expired sign-ins", isOn: $renewSignIn)
            Text("Runs `claude auth status` or `codex login status`, which usually renews the sign-in. You're notified only when it doesn't.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func notify(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .onChange(of: isOn.wrappedValue) { _, on in
                if on { Notifier.requestPermissionIfEnabled() }
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
