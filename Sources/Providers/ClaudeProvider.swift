import Foundation
import Synchronization

struct ClaudeProvider: UsageProvider {
    let id = ProviderID.claude
    static let keychainService = "Claude Code-credentials"

    struct Credentials: Decodable {
        struct OAuth: Decodable {
            var accessToken: String
            var expiresAt: Double?
            var subscriptionType: String?
            var rateLimitTier: String?
        }

        var claudeAiOauth: OAuth?

        var isExpired: Bool {
            guard let ms = claudeAiOauth?.expiresAt else { return true }
            return Date(timeIntervalSince1970: ms / 1000) <= .now
        }
    }

    static var credentialsFile: URL {
        let env = ProcessInfo.processInfo.environment
        let dir = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        return dir.appending(path: ".credentials.json")
    }

    static func readFile() -> Credentials? {
        (try? Data(contentsOf: credentialsFile))
            .flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
            .flatMap { $0.claudeAiOauth == nil ? nil : $0 }
    }

    static func readKeychain() -> Credentials? {
        Keychain.readViaSecurityTool(service: keychainService)
            .flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
            .flatMap { $0.claudeAiOauth == nil ? nil : $0 }
    }

    /// Claude Code keeps the live token in the Keychain on macOS; the file is often stale.
    /// An unexpired file wins, so no Keychain read is needed at all then.
    static func resolveCredentials() throws -> Credentials {
        let file = readFile()
        if let file, !file.isExpired { return file }
        if let keychain = readKeychain() { return keychain }
        if let file { return file }
        throw ProviderError.notConfigured("Run `claude` and sign in.")
    }

    #if DEBUG
    /// `-debugExpiredSignIn YES`: acts as if the token expired, to test the sign-in alert.
    private static var debugExpired: Bool { UserDefaults.standard.bool(forKey: "debugExpiredSignIn") }
    #else
    private static let debugExpired = false
    #endif

    var activityFolder: URL {
        Self.credentialsFile.deletingLastPathComponent().appending(path: "projects")
    }

    func isInstalled() -> Bool {
        Executable.exists("claude") || FileManager.default.fileExists(atPath: Self.credentialsFile.path)
            || Keychain.exists(service: Self.keychainService)
    }

    func fetch() async throws -> Snapshot {
        let credentials = try Self.resolveCredentials()
        guard let oauth = credentials.claudeAiOauth else { throw ProviderError.notConfigured("Run `claude` and sign in.") }
        if credentials.isExpired || Self.debugExpired {
            throw ProviderError.unauthorized("Sign-in expired. Run `claude` once to refresh it.")
        }
        let headers = Self.requestHeaders(token: oauth.accessToken)
        let hint = "Claude rejected the sign-in. Run `claude` and sign in again."
        let usage: Usage
        do {
            // cedar_ember=1 adds banked reset grants. Fall back to plain usage if it's refused.
            usage = try await HTTP.json(
                Usage.self, URLRequest("https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1", headers: headers), unauthorizedHint: hint
            )
        } catch ProviderError.http(400), ProviderError.unauthorized {
            usage = try await HTTP.json(
                Usage.self, URLRequest("https://api.anthropic.com/api/oauth/usage", headers: headers), unauthorizedHint: hint
            )
        }
        // The profile (email) only changes with the sign-in; one request per token, not per refresh.
        var profile = Self.profiles.withLock { $0[oauth.accessToken] }
        if profile == nil {
            profile = try? await HTTP.json(
                Profile.self, URLRequest("https://api.anthropic.com/api/oauth/profile", headers: headers), unauthorizedHint: hint
            )
            if let profile { Self.profiles.withLock { $0 = [oauth.accessToken: profile] } }
        }
        var snapshot = Self.snapshot(usage: usage, profile: profile, oauth: oauth)
        snapshot.signInExpiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        return snapshot
    }

    // MARK: - Parsing

    struct Usage: Decodable {
        struct Window: Decodable {
            var utilization: Double?
            var resets_at: String?
        }

        struct Extra: Decodable {
            var is_enabled: Bool?
            var monthly_limit: Double?
            var used_credits: Double?
        }

        /// Newer shape: one entry per limit, including model-scoped weekly limits.
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { var display_name: String? }
                var model: Model?
            }

            var kind: String?
            var percent: Double?
            var resets_at: String?
            var scope: Scope?
        }

        struct Breakdown: Decodable {
            struct Row: Decodable {
                var display_name: String?
                var percent: Double?
            }

            var rows: [Row]?
        }

        var five_hour: Window?
        var seven_day: Window?
        var seven_day_opus: Window?
        var seven_day_sonnet: Window?
        var extra_usage: Extra?
        var limits: [Limit]?
        var seven_day_breakdown: Breakdown?
        var cedar_ember: CedarEmber?
    }

    struct CedarEmber: Decodable {
        struct Grant: Decodable {
            var id: String?
            var usable_now: Bool?
            var resets_left: Int?
            var starts_at: String?
            var ends_at: String?
            var paused: Bool?
        }

        var eligible: Bool?
        var grants: [Grant]?
        var next_grant_id: String?
    }

    /// Counts resets in grants that are live now: not paused, started, not expired.
    static func banked(_ cedar: CedarEmber?, now: Date = .now) -> BankedResets? {
        guard let cedar, cedar.eligible != false else { return nil }
        let live = (cedar.grants ?? []).filter { grant in
            guard grant.paused != true, (grant.resets_left ?? 0) > 0 else { return false }
            if let start = ISODate.parse(grant.starts_at), start > now { return false }
            if let end = ISODate.parse(grant.ends_at), end <= now { return false }
            return true
        }
        let count = live.reduce(0) { $0 + ($1.resets_left ?? 0) }
        guard count > 0 else { return nil }
        let next = live.first { $0.id != nil && $0.id == cedar.next_grant_id && $0.usable_now == true }
        return BankedResets(count: count, nextExpiry: live.compactMap { ISODate.parse($0.ends_at) }.min(), grantID: next?.id)
    }

    /// Spends one banked reset. Each call gets a fresh request id, so it's one claim per click.
    static func redeem(grantID: String) async throws -> String {
        let credentials = try resolveCredentials()
        guard let oauth = credentials.claudeAiOauth, !credentials.isExpired else {
            throw ProviderError.unauthorized("Sign-in expired. Run `claude` once to refresh it.")
        }
        let headers = requestHeaders(token: oauth.accessToken)
        let hint = "Claude rejected the sign-in. Run `claude` and sign in again."
        let profile = try await HTTP.json(Profile.self, URLRequest("https://api.anthropic.com/api/oauth/profile", headers: headers), unauthorizedHint: hint)
        guard let org = profile.organization?.uuid else { throw ProviderError.badResponse("no organization") }
        var request = URLRequest("https://api.anthropic.com/api/organizations/\(org)/reset_rate_limits", method: "POST", headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "program": "cedar_ember", "grant_id": grantID, "request_id": UUID().uuidString.lowercased(),
        ])
        struct Claim: Decodable { var result: String }
        let claim = try await HTTP.json(Claim.self, request, unauthorizedHint: hint)
        return claimMessage(claim.result)
    }

    static func claimMessage(_ result: String) -> String {
        switch result {
        case "reset": "Limits reset. Fresh quota is available."
        case "not_limited": "Nothing to reset right now. The reset is still banked."
        case "already_used": "That reset was already used."
        case "cooldown": "Claude is cooling down. Try again shortly."
        case "ineligible": "This account can't use banked resets."
        default: "Claude couldn't confirm the reset. Refresh to check."
        }
    }

    private static let profiles = Mutex<[String: Profile]>([:])

    static func requestHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            // Banked resets ("cedar_ember") are only reported to a current Claude Code CLI.
            "User-Agent": "claude-cli/\(cliVersion) (external, cli)",
        ]
    }

    struct Profile: Decodable, Sendable {
        struct Account: Decodable, Sendable {
            var email_address: String?
            var email: String?
        }

        struct Organization: Decodable, Sendable {
            var uuid: String?
        }

        var account: Account?
        var organization: Organization?
    }

    static func snapshot(usage: Usage, profile: Profile?, oauth: Credentials.OAuth, now: Date = .now) -> Snapshot {
        let windows = usage.limits.map(windows(from:)).flatMap { $0.isEmpty ? nil : $0 } ?? legacyWindows(usage)
        var details: [Detail] = []
        if let extra = usage.extra_usage, extra.is_enabled == true, let used = extra.used_credits {
            let limit = extra.monthly_limit.map { " of \(Money.usd(cents: $0))" } ?? ""
            details.append(Detail(label: "Extra usage", value: Money.usd(cents: used) + limit))
        }
        // Where this week's usage went, e.g. "Claude Code 100%". Zero rows are noise.
        for row in usage.seven_day_breakdown?.rows ?? [] {
            guard let name = row.display_name, let percent = row.percent, percent > 0 else { continue }
            details.append(Detail(label: "\(name) this week", value: "\(Int(percent.rounded()))%"))
        }
        let user = profile?.account?.email_address ?? profile?.account?.email
        return Snapshot(
            windows: windows,
            account: Account(user: user, plan: plan(subscription: oauth.subscriptionType, tier: oauth.rateLimitTier)),
            details: details,
            banked: banked(usage.cedar_ember, now: now),
            fetchedAt: now
        )
    }

    /// Installed Claude Code version, without running it: the native installer links `claude`
    /// to `versions/<version>`; npm installs keep it in package.json.
    static var cliVersion: String {
        let fallback = "2.1.306"
        guard let binary = Executable.path("claude")?.resolvingSymlinksInPath() else { return fallback }
        if isVersion(binary.lastPathComponent) { return binary.lastPathComponent }
        var folder = binary.deletingLastPathComponent()
        for _ in 0 ..< 4 {
            if let data = try? Data(contentsOf: folder.appending(path: "package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["name"] as? String == "@anthropic-ai/claude-code",
               let version = json["version"] as? String
            {
                return version
            }
            folder.deleteLastPathComponent()
        }
        return fallback
    }

    static func isVersion(_ text: String) -> Bool {
        text.wholeMatch(of: /\d+\.\d+\.\d+/) != nil
    }

    static let sessionLength: TimeInterval = 5 * 3600
    static let weekLength: TimeInterval = 7 * 86400

    static func windows(from limits: [Usage.Limit]) -> [UsageWindow] {
        limits.compactMap { limit in
            guard let percent = limit.percent else { return nil }
            let resets = ISODate.parse(limit.resets_at)
            switch limit.kind {
            case "session":
                return UsageWindow(id: "session", label: "Session", kind: .primary, used: percent / 100, resetsAt: resets, duration: Self.sessionLength)
            case "weekly_all":
                return UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: percent / 100, resetsAt: resets, duration: Self.weekLength)
            case "weekly_scoped":
                let model = limit.scope?.model?.display_name ?? "Model"
                return UsageWindow(id: "weekly-\(model.lowercased())", label: "\(model) weekly", kind: .secondary, used: percent / 100, resetsAt: resets, duration: Self.weekLength)
            default:
                return nil
            }
        }
    }

    static func legacyWindows(_ usage: Usage) -> [UsageWindow] {
        let entries: [(String, String, UsageWindow.Kind, Usage.Window?)] = [
            ("session", "Session", .primary, usage.five_hour),
            ("weekly", "Weekly", .primary, usage.seven_day),
            ("weekly-opus", "Opus weekly", .secondary, usage.seven_day_opus),
            ("weekly-sonnet", "Sonnet weekly", .secondary, usage.seven_day_sonnet),
        ]
        return entries.compactMap { id, label, kind, window -> UsageWindow? in
            guard let utilization = window?.utilization else { return nil }
            return UsageWindow(
                id: id, label: label, kind: kind, used: utilization / 100, resetsAt: ISODate.parse(window?.resets_at),
                duration: id == "session" ? Self.sessionLength : Self.weekLength
            )
        }
    }

    /// "max" + "default_claude_max_20x" -> "Max 20x".
    static func plan(subscription: String?, tier: String?) -> String? {
        guard let base = subscription ?? tier else { return nil }
        let names = ["max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"]
        let name = names.first { base.lowercased().contains($0.key) }?.value ?? base.capitalized
        let multiplier = tier?.split(separator: "_").last.flatMap { $0.hasSuffix("x") && Int($0.dropLast()) != nil ? String($0) : nil }
        return [name, multiplier].compactMap(\.self).joined(separator: " ")
    }
}
