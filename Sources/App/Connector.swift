import AppKit
import Observation

/// User actions on a provider card: spending a banked reset.
@MainActor
@Observable
final class Connector {
    /// Outcome of the last banked reset, shown on the card.
    private(set) var notices: [ProviderID: String] = [:]
    private(set) var redeeming: Set<ProviderID> = []

    @ObservationIgnored private let refresher: Refresher

    init(refresher: Refresher) {
        self.refresher = refresher
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
}
