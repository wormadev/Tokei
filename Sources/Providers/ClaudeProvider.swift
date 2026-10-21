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
            throw ProviderError.notConfigured(connected
                ? "Keychain access lost. Click Connect in Settings › Providers."
                : "Click Connect in Settings › Providers to read Claude Code's sign-in.")
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

        var five_hour: Window?
        var seven_day: Window?
        var seven_day_opus: Window?
        var seven_day_sonnet: Window?
        var extra_usage: Extra?
    }

    struct Profile: Decodable {
        struct Account: Decodable {
            var email_address: String?
            var email: String?
        }

        var account: Account?
    }

    static func snapshot(usage: Usage, profile: Profile?, oauth: Credentials.OAuth, now: Date = .now) -> Snapshot {
        let entries: [(String, String, UsageWindow.Kind, Usage.Window?)] = [
            ("session", "Session", .primary, usage.five_hour),
            ("weekly", "Weekly", .primary, usage.seven_day),
            ("opus", "Opus weekly", .secondary, usage.seven_day_opus),
            ("sonnet", "Sonnet weekly", .secondary, usage.seven_day_sonnet),
        ]
        let windows = entries.compactMap { id, label, kind, window -> UsageWindow? in
            guard let utilization = window?.utilization else { return nil }
            return UsageWindow(id: id, label: label, kind: kind, used: utilization / 100, resetsAt: ISODate.parse(window?.resets_at))
        }
        var details: [Detail] = []
        if let extra = usage.extra_usage, extra.is_enabled == true, let used = extra.used_credits {
            let limit = extra.monthly_limit.map { " of \(Money.usd(cents: $0))" } ?? ""
            details.append(Detail(label: "Extra usage", value: Money.usd(cents: used) + limit))
        }
        let user = profile?.account?.email_address ?? profile?.account?.email
        return Snapshot(
            windows: windows,
            account: Account(user: user, plan: plan(subscription: oauth.subscriptionType, tier: oauth.rateLimitTier)),
            details: details,
            fetchedAt: now
        )
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
