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
            renewFailures[id] = ("Still expired. Open Terminal to run \(command.cli), then quit it with /exit.", .now)
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
                await refresher.refreshAfterCurrent(id)
                if refresher.states[id]?.needsSignIn != true { return }
            }
        }
    }
}
