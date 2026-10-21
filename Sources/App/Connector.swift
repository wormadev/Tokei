import AppKit
import Observation

/// User-initiated sign-in from the panel card. The only code allowed to show a Keychain prompt.
@MainActor
@Observable
final class Connector {
    private(set) var errors: [ProviderID: String] = [:]
    /// Outcome of the last banked reset, shown on the card.
    private(set) var notices: [ProviderID: String] = [:]
    private(set) var redeeming: Set<ProviderID> = []

    @ObservationIgnored private let refresher: Refresher

    init(refresher: Refresher) {
        self.refresher = refresher
    }

    func actionTitle(_ id: ProviderID) -> String? {
        id == .claude ? "Connect" : nil
    }

    func redeem(_ id: ProviderID, grantID: String) {
        guard id == .claude, !redeeming.contains(id) else { return }
        redeeming.insert(id)
        notices[id] = nil
        Task {
            defer { redeeming.remove(id) }
            do {
                notices[id] = try await ClaudeProvider.redeem(grantID: grantID)
            } catch {
                notices[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await refresher.refresh(id)
        }
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
