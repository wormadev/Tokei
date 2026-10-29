import AppKit
import Observation

/// User actions on a provider card: spending a banked reset, renewing an expired sign-in.
@MainActor
@Observable
final class Connector {
    /// Outcome of the last banked reset, shown on the card.
    private(set) var notices: [ProviderID: String] = [:]
    /// Why the last sign-in renewal failed, and when.
    private(set) var renewFailures: [ProviderID: (message: String, at: Date)] = [:]
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
            await refresher.refreshAfterCurrent(id)
        }
    }

    /// The CLI's own status command, which may renew its expired token on the way. Tokei
    /// itself never touches the refresh token.
    static let statusCommands: [ProviderID: (cli: String, arguments: [String])] = [
        .claude: ("claude", ["auth", "status"]),
        .codex: ("codex", ["login", "status"]),
    ]

    /// True when the sign-in works again afterwards.
    @discardableResult
    func renewSignIn(_ id: ProviderID) async -> Bool {
        guard let command = Self.statusCommands[id], !renewing.contains(id) else { return false }
        guard let cli = Executable.path(command.cli) else {
            renewFailures[id] = ("Couldn't find \(command.cli). Run it in Terminal.", .now)
            return false
        }
        renewing.insert(id)
        renewFailures[id] = nil
        defer { renewing.remove(id) }
        do {
            try await Executable.run(cli, command.arguments)
        } catch {
            renewFailures[id] = ("Couldn't run \(command.cli): \(error.localizedDescription)", .now)
            return false
        }
        await refresher.refreshAfterCurrent(id)
        guard refresher.states[id]?.needsSignIn != true else {
            renewFailures[id] = ("Still expired. Open Terminal and run \(command.cli).", .now)
            return false
        }
        return true
    }

    /// A failure says nothing once any later refresh has run: that one may have fixed it.
    func renewFailure(_ id: ProviderID, lastAttempt: Date?) -> String? {
        guard let failure = renewFailures[id], failure.at >= lastAttempt ?? .distantPast else { return nil }
        return failure.message
    }
}
