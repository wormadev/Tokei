import AppKit
import Observation

/// User-initiated sign-ins, shared by the panel cards and Settings. The only code allowed to
/// show a Keychain prompt or open a browser.
@MainActor
@Observable
final class Connector {
    private(set) var copilotCode: String?
    private(set) var errors: [ProviderID: String] = [:]
    private(set) var copilotSignedIn = CopilotProvider.token != nil

    @ObservationIgnored private let refresher: Refresher
    @ObservationIgnored private var signIn: Task<Void, Never>?

    init(refresher: Refresher) {
        self.refresher = refresher
    }

    func actionTitle(_ id: ProviderID) -> String? {
        switch id {
        case .claude: "Connect"
        case .copilot: "Sign in with GitHub"
        default: nil
        }
    }

    func connect(_ id: ProviderID) {
        errors[id] = nil
        switch id {
        case .claude: connectClaude()
        case .copilot: signInCopilot()
        default: break
        }
    }

    private func connectClaude() {
        Task {
            // SecItemCopyMatching blocks while the prompt is up; keep the main thread free.
            let ok = await Task.detached { ClaudeProvider.connect() }.value
            if ok {
                await refresher.refresh(.claude)
            } else {
                errors[.claude] = "No Keychain access. Run `claude` and sign in, then Connect and choose Always Allow."
            }
        }
    }

    private func signInCopilot() {
        signIn = Task {
            do {
                let code = try await CopilotDeviceFlow.start()
                copilotCode = code.user_code
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.user_code, forType: .string)
                if let url = URL(string: code.verification_uri) { NSWorkspace.shared.open(url) }
                try await CopilotDeviceFlow.complete(code)
                copilotCode = nil
                copilotSignedIn = true
                await refresher.refresh(.copilot)
            } catch {
                // Cancel mid-request surfaces as URLError.cancelled, not CancellationError.
                if Task.isCancelled { return }
                copilotCode = nil
                errors[.copilot] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelCopilot() {
        signIn?.cancel()
        copilotCode = nil
    }

    func signOutCopilot() {
        CopilotDeviceFlow.signOut()
        copilotSignedIn = false
        refresher.clear(.copilot)
    }
}
