import Foundation

struct ClaudeProvider: UsageProvider {
    let id = ProviderID.claude
    static let keychainService = "Claude Code-credentials"
    /// Set once the user clicked Connect and allowed Keychain access.
    static let keychainConnectedKey = "claude.keychainConnected"

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

    static func readKeychain(allowUI: Bool) -> Credentials? {
        Keychain.read(service: keychainService, allowUI: allowUI)
            .flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
            .flatMap { $0.claudeAiOauth == nil ? nil : $0 }
    }

    /// Settings › Connect: the one place that may show the Keychain prompt.
    @discardableResult
    static func connect() -> Bool {
        guard readKeychain(allowUI: true) != nil else { return false }
        UserDefaults.standard.set(true, forKey: keychainConnectedKey)
        return true
    }

    /// Claude Code keeps the live token in the Keychain on macOS; the file is often stale.
    /// An unexpired file wins, so no Keychain read is needed at all then.
    static func resolveCredentials() throws -> Credentials {
        let file = readFile()
        if let file, !file.isExpired { return file }
        let connected = UserDefaults.standard.bool(forKey: keychainConnectedKey)
        if connected, let keychain = readKeychain(allowUI: false) { return keychain }
        if Keychain.exists(service: keychainService) {
            // Claude Code re-creating its item resets the Always Allow grant.
            throw ProviderError.needsConnect(connected
                ? "Keychain access was reset. Connect again and choose Always Allow."
                : "Connect to read Claude Code's sign-in.")
        }
        if let file { return file }
        throw ProviderError.notConfigured("Run `claude` and sign in.")
    }

    func fetch() async throws -> Snapshot {
        let credentials = try Self.resolveCredentials()
        guard let oauth = credentials.claudeAiOauth else { throw ProviderError.notConfigured("Run `claude` and sign in.") }
        if credentials.isExpired {
            throw ProviderError.unauthorized("Sign-in expired. Run `claude` once to refresh it.")
        }
        let headers = [
            "Authorization": "Bearer \(oauth.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "claude-code/2.1.0",
        ]
        let hint = "Claude rejected the sign-in. Run `claude` and sign in again."
        let usage = try await HTTP.json(
            Usage.self, URLRequest("https://api.anthropic.com/api/oauth/usage", headers: headers), unauthorizedHint: hint
        )
        let profile = try? await HTTP.json(
            Profile.self, URLRequest("https://api.anthropic.com/api/oauth/profile", headers: headers), unauthorizedHint: hint
        )
        return Self.snapshot(usage: usage, profile: profile, oauth: oauth)
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
    }

    struct Profile: Decodable {
        struct Account: Decodable {
            var email_address: String?
            var email: String?
        }

        var account: Account?
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
            fetchedAt: now
        )
    }

    static func windows(from limits: [Usage.Limit]) -> [UsageWindow] {
        limits.compactMap { limit in
            guard let percent = limit.percent else { return nil }
            let resets = ISODate.parse(limit.resets_at)
            switch limit.kind {
            case "session":
                return UsageWindow(id: "session", label: "Session", kind: .primary, used: percent / 100, resetsAt: resets)
            case "weekly_all":
                return UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: percent / 100, resetsAt: resets)
            case "weekly_scoped":
                let model = limit.scope?.model?.display_name ?? "Model"
                return UsageWindow(id: "weekly-\(model.lowercased())", label: "\(model) weekly", kind: .secondary, used: percent / 100, resetsAt: resets)
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
            return UsageWindow(id: id, label: label, kind: kind, used: utilization / 100, resetsAt: ISODate.parse(window?.resets_at))
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
