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

        /// No expiry recorded counts as unexpired; the API's 401 decides then.
        var isExpired: Bool {
            guard let ms = claudeAiOauth?.expiresAt else { return false }
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

    static let keychainGate = KeychainGate()

    static func readKeychain(userInitiated: Bool) throws -> Credentials? {
        try keychainGate.read(userInitiated: userInitiated, isUnlocked: Keychain.isDefaultUnlocked) {
            Keychain.readViaSecurityTool(service: keychainService)
        }
        .flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
        .flatMap { $0.claudeAiOauth == nil ? nil : $0 }
    }

    /// Claude Code keeps the live token in the Keychain on macOS; the file is often stale.
    /// An unexpired file wins, so no Keychain read is needed at all then. A Keychain that
    /// can't be read throws rather than falling back to the stale file.
    static func resolveCredentials(userInitiated: Bool) throws -> Credentials {
        let file = readFile()
        if let file, !file.isExpired { return file }
        if let keychain = try readKeychain(userInitiated: userInitiated) { return keychain }
        if let file { return file }
        throw ProviderError.notConfigured("Not signed in. Run `claude` to sign in.")
    }

    #if DEBUG
    /// `-debugExpiredSignIn YES`: acts as if Claude rejected the token, to test the sign-in alert.
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

    func fetch(userInitiated: Bool) async throws -> Snapshot {
        let credentials = try Self.resolveCredentials(userInitiated: userInitiated)
        guard let oauth = credentials.claudeAiOauth else { throw ProviderError.notConfigured("Not signed in. Run `claude` to sign in.") }
        let hint = Self.rejected
        if Self.debugExpired { throw ProviderError.unauthorized(hint) }
        if credentials.isExpired {
            throw ProviderError.signInExpired(Self.expired)
        }
        let headers = Self.requestHeaders(token: oauth.accessToken)
        let usage: Usage
        do {
            // cedar_ember=1 adds banked reset grants. Fall back to plain usage if it's refused.
            usage = try await HTTP.json(
                Usage.self, URLRequest("https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1", headers: headers), unauthorizedHint: hint
            )
        } catch ProviderError.http(400), ProviderError.http(403), ProviderError.unauthorized {
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
            /// Sometimes a string ("11").
            var percent: FlexibleDouble?
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

    /// Decodes leniently: it's an optional extra, so a shape change here must not fail usage.
    struct CedarEmber: Decodable {
        struct Grant: Decodable {
            var id: String?
            var usable_now: Bool?
            var resets_left: Int?
            var starts_at: String?
            var ends_at: String?
            var paused: Bool?
            var clears: [String]?
            var type: String?
            var gives_back_weekly: Bool?

            /// Claude Code's own derivation, so the names match what the CLI shows.
            var kind: BankedResets.Kind {
                if gives_back_weekly == true { return .fable }
                if let type, let kind = BankedResets.Kind(rawValue: type) { return kind }
                let clears = Set(clears ?? [])
                if clears == ["five_hour"] { return .session }
                if !clears.isEmpty, !clears.contains("five_hour") { return .weekly }
                return .full
            }
        }

        /// Steps over a grant that didn't decode.
        private struct Skip: Decodable {
            init(from decoder: Decoder) {}
        }

        enum CodingKeys: String, CodingKey { case eligible, grants, next_grant_id }

        var eligible: Bool?
        var grants: [Grant]?
        /// The grant Claude Code would spend next.
        var next_grant_id: String?

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            eligible = try? container.decodeIfPresent(Bool.self, forKey: .eligible)
            next_grant_id = try? container.decodeIfPresent(String.self, forKey: .next_grant_id)
            guard var list = try? container.nestedUnkeyedContainer(forKey: .grants) else { return }
            var grants: [Grant] = []
            while !list.isAtEnd {
                if let grant = try? list.decode(Grant.self) {
                    grants.append(grant)
                } else if (try? list.decode(Skip.self)) == nil, (try? list.decodeNil()) != true {
                    break
                }
            }
            self.grants = grants
        }
    }

    /// One entry per kind, in `Kind` order. Live grants only: not paused, started, not expired,
    /// with resets left or usable now. The Reset spends the first usable grant of that kind.
    static func banked(_ cedar: CedarEmber?, now: Date = .now) -> [BankedResets] {
        guard let cedar, cedar.eligible != false else { return [] }
        let live = (cedar.grants ?? []).filter { grant in
            guard grant.paused != true, (grant.resets_left ?? 0) > 0 || grant.usable_now == true else { return false }
            if let start = ISODate.parse(grant.starts_at), start > now { return false }
            if let end = ISODate.parse(grant.ends_at), end <= now { return false }
            return true
        }
        return BankedResets.Kind.allCases.compactMap { kind in
            let grants = live.filter { $0.kind == kind }
            let count = grants.reduce(0) { $0 + ($1.resets_left ?? 0) }
            guard count > 0 else { return nil }
            let usable = grants.filter { $0.id != nil && $0.usable_now == true }
            // Claude's own pick first, so a reset spends the grant Claude Code would.
            let next = usable.first { $0.id == cedar.next_grant_id } ?? usable.first
            return BankedResets(kind: kind, count: count, nextExpiry: grants.compactMap { ISODate.parse($0.ends_at) }.min(), grantID: next?.id)
        }
    }

    /// Spends one banked reset. The same `requestID` on a retry makes it the same claim.
    static func redeem(grantID: String, requestID: String) async throws -> RedeemOutcome {
        let credentials = try resolveCredentials(userInitiated: true)
        guard let oauth = credentials.claudeAiOauth, !credentials.isExpired else {
            throw ProviderError.unauthorized(Self.expired)
        }
        let headers = requestHeaders(token: oauth.accessToken)
        let hint = Self.rejected
        let profile = try await HTTP.json(Profile.self, URLRequest("https://api.anthropic.com/api/oauth/profile", headers: headers), unauthorizedHint: hint)
        guard let org = profile.organization?.uuid else { throw ProviderError.badResponse("no organization") }
        var request = URLRequest("https://api.anthropic.com/api/organizations/\(org)/reset_rate_limits", method: "POST", headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "program": "cedar_ember", "grant_id": grantID, "request_id": requestID,
        ])
        struct Claim: Decodable { var result: String }
        let claim = try await HTTP.json(Claim.self, request, unauthorizedHint: hint)
        return claimOutcome(claim.result)
    }

    static func claimOutcome(_ result: String) -> RedeemOutcome {
        switch result {
        case "reset", "already_used": RedeemOutcome(message: "Limits refilled.", settled: true, refilled: true)
        case "not_limited": RedeemOutcome(message: "You're not limited right now, so the reset is still banked.", settled: true)
        case "cooldown": RedeemOutcome(message: "Claude is cooling down. Try again in a minute.", settled: true)
        case "ineligible": RedeemOutcome(message: "This account can't use banked resets.", settled: true)
        default: RedeemOutcome(message: "Claude didn't confirm the reset. Try again in a moment; it won't be spent twice.", settled: false)
        }
    }

    static let expired = "Sign-in expired"
    static let rejected = "Signed out. Run `claude` to sign in again."

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
        let windows = (usage.limits.map(windows(from:)).flatMap { $0.isEmpty ? nil : $0 } ?? legacyWindows(usage)).withUniqueIDs()
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
            resets: banked(usage.cedar_ember, now: now),
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

    /// A session reported without a number hasn't started: no message yet in this window.
    /// Weekly-only plans leave the session out entirely, so none is invented then.
    static func windows(from limits: [Usage.Limit]) -> [UsageWindow] {
        limits.compactMap { limit in
            let resets = ISODate.parse(limit.resets_at)
            guard let percent = limit.percent?.value else {
                guard limit.kind == "session" else { return nil }
                return UsageWindow(id: "session", label: "Session", kind: .primary, used: 0, resetsAt: nil, duration: Self.sessionLength)
            }
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
            guard let window else { return nil }
            // Same as the limits array: a session object without a number hasn't started.
            guard let utilization = window.utilization ?? (id == "session" ? 0 : nil) else { return nil }
            return UsageWindow(
                id: id, label: label, kind: kind, used: utilization / 100, resetsAt: ISODate.parse(window.resets_at),
                duration: id == "session" ? Self.sessionLength : Self.weekLength
            )
        }
    }

    /// Oct 2026 rename: Max 5x is "Max", Max 20x is "Ultra". Tokens still carry the old tier ids,
    /// so "max" + "default_claude_max_20x" -> "Ultra".
    static func plan(subscription: String?, tier: String?) -> String? {
        guard let base = subscription ?? tier else { return nil }
        let ids = [subscription, tier].compactMap { $0?.lowercased() }
        if ids.contains(where: { $0.contains("ultra") || $0.hasSuffix("max_20x") }) { return "Ultra" }
        let names = ["max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"]
        let name = names.first { base.lowercased().contains($0.key) }?.value ?? base.capitalized
        let multiplier = name == "Max" ? nil : tier?.split(separator: "_").last.flatMap { $0.hasSuffix("x") && Int($0.dropLast()) != nil ? String($0) : nil }
        return [name, multiplier].compactMap(\.self).joined(separator: " ")
    }
}
