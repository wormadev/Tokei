import AppKit
import Observation

/// User actions on a provider card: spending a banked reset, renewing an expired sign-in.
@MainActor
@Observable
final class Connector {
    /// Outcome of the last banked reset or sign-in renewal, shown on the card.
    private(set) var notices: [ProviderID: String] = [:]
    private(set) var redeeming: Set<ProviderID> = []
    private(set) var renewing: Set<ProviderID> = []

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

    /// The CLI's own status command, which may renew its expired token on the way. Tokei
    /// itself never touches the refresh token.
    static let statusCommands: [ProviderID: (cli: String, arguments: [String])] = [
        .claude: ("claude", ["auth", "status"]),
        .codex: ("codex", ["login", "status"]),
    ]

    func renewSignIn(_ id: ProviderID) {
        guard let command = Self.statusCommands[id], !renewing.contains(id) else { return }
        guard let cli = Executable.path(command.cli) else {
            notices[id] = "Couldn't find \(command.cli). Run it in Terminal."
            return
        }
        renewing.insert(id)
        notices[id] = nil
        Task {
            defer { renewing.remove(id) }
            do {
                try await Executable.run(cli, command.arguments)
            } catch {
                notices[id] = "Couldn't run \(command.cli): \(error.localizedDescription)"
                return
            }
            await refresher.refresh(id)
            if refresher.states[id]?.needsSignIn == true {
                notices[id] = "Still expired. Open Terminal and run \(command.cli)."
            }
        }
    }
}
