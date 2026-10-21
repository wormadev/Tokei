import AppKit
import Observation

/// User-initiated sign-in from the panel card. The only code allowed to show a Keychain prompt.
@MainActor
@Observable
final class Connector {
    private(set) var errors: [ProviderID: String] = [:]

    @ObservationIgnored private let refresher: Refresher

    init(refresher: Refresher) {
        self.refresher = refresher
    }

    func actionTitle(_ id: ProviderID) -> String? {
        id == .claude ? "Connect" : nil
    }

    func connect(_ id: ProviderID) {
        guard id == .claude else { return }
        errors[id] = nil
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
}
