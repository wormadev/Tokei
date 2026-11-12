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

    /// Request ids of spends the server hasn't answered yet, reused on retry.
    @ObservationIgnored private var pendingClaims: [String: String] = [:]

    /// Keyed by kind, not grant: after a spend the server answered but we never heard, the
    /// spent grant can drop out of the list and the retry would target the next one.
    func redeem(_ id: ProviderID, _ resets: BankedResets, grantID: String) {
        guard !redeeming.contains(id) else { return }
        redeeming.insert(id)
        notices[id] = nil
        let key = "\(id.rawValue)/\(resets.name)"
        let requestID = pendingClaims[key] ?? UUID().uuidString.lowercased()
        pendingClaims[key] = requestID
        Task {
            defer { redeeming.remove(id) }
            let outcome: RedeemOutcome
            do {
                outcome = switch id {
                case .claude: try await ClaudeProvider.redeem(grantID: grantID, requestID: requestID)
                case .codex: try await CodexProvider.redeem(creditID: grantID, requestID: requestID)
                }
            } catch {
                outcome = .failure(error)
            }
            if outcome.settled { pendingClaims[key] = nil }
            notices[id] = outcome.message
            await refresher.refreshAfterCurrent(id, userInitiated: true)
            if outcome.refilled {
                // The usage endpoint can lag the reset by a few seconds.
                try? await Task.sleep(for: .seconds(5))
                await refresher.refresh(id, userInitiated: true)
            }
            try? await Task.sleep(for: .seconds(10))
            if notices[id] == outcome.message { notices[id] = nil }
        }
    }

    /// The CLI's own status command, which may renew its expired token on the way. Tokei
    /// itself never touches the refresh token.
    nonisolated static let statusCommands: [ProviderID: (cli: String, arguments: [String])] = [
        .claude: ("claude", ["auth", "status"]),
        .codex: ("codex", ["login", "status"]),
    ]

    /// False when the sign-in is known to still be broken afterwards.
    @discardableResult
    func renewSignIn(_ id: ProviderID, userInitiated: Bool) async -> Bool {
        guard let command = Self.statusCommands[id], !renewing.contains(id) else { return false }
        guard let cli = Executable.path(command.cli) else {
            renewFailures[id] = ("Couldn't find `\(command.cli)` on this Mac.", .now)
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
        await refresher.refreshAfterCurrent(id, userInitiated: userInitiated)
        // A 429 says nothing about the sign-in either way: no failure, no notification.
        if refresher.states[id]?.rateLimited == true { return true }
        guard refresher.states[id]?.needsSignIn != true else {
            renewFailures[id] = ("Still expired. Start `\(command.cli)` in Terminal to renew it, then quit with /exit.", .now)
            return false
        }
        return true
    }

    /// Stale once a later fetch succeeded: the sign-in worked again since.
    func renewFailure(_ id: ProviderID, lastSuccess: Date?) -> String? {
        guard let failure = renewFailures[id], failure.at >= lastSuccess ?? .distantPast else { return nil }
        return failure.message
    }

    /// Fallback when the status command didn't renew: a real CLI session does. Then checks
    /// every 15 s for two minutes, so the alert clears soon after, despite failure backoff.
    func openTerminal(_ id: ProviderID) {
        guard let command = Self.statusCommands[id], let cli = Executable.path(command.cli), !renewing.contains(id) else { return }
        // A .command file opens in Terminal without the Automation permission scripting it needs.
        let script = FileManager.default.temporaryDirectory.appending(path: "tokei-\(command.cli).command")
        do {
            try "#!/bin/zsh -l\ncd ~\nexec '\(cli.path)'\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            renewFailures[id] = ("Couldn't open Terminal: \(error.localizedDescription)", .now)
            return
        }
        NSWorkspace.shared.open(script)
        renewing.insert(id)
        Task {
            defer { renewing.remove(id) }
            for _ in 0 ..< 8 {
                try? await Task.sleep(for: .seconds(15))
                if let state = refresher.states[id], state.rateLimited == true, let retryAt = state.retryAt, retryAt > .now { continue }
                await refresher.refreshAfterCurrent(id)
                if refresher.states[id]?.needsSignIn != true { return }
            }
        }
    }
}
