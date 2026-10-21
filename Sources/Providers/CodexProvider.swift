import Foundation

struct CodexProvider: UsageProvider {
    let id = ProviderID.codex

    struct Auth: Decodable {
        struct Tokens: Decodable {
            var access_token: String
            var id_token: String?
            var account_id: String?
        }

        var tokens: Tokens?
    }

    static var authFile: URL {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let dir = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        return dir.appending(path: "auth.json")
    }

    var activityFolder: URL {
        Self.authFile.deletingLastPathComponent().appending(path: "sessions")
    }

    func isInstalled() -> Bool {
        Executable.exists("codex") || FileManager.default.fileExists(atPath: Self.authFile.path)
    }

    func fetch() async throws -> Snapshot {
        guard let data = try? Data(contentsOf: Self.authFile),
              let tokens = (try? JSONDecoder().decode(Auth.self, from: data))?.tokens
        else {
            throw ProviderError.notConfigured("Run `codex login` to sign in.")
        }
        if let exp = JWT(tokens.access_token)?.expiresAt, exp <= .now {
            throw ProviderError.unauthorized("Sign-in expired. Run `codex` once to refresh it.")
        }
        var headers = [
            "Authorization": "Bearer \(tokens.access_token)",
            "Accept": "application/json",
            "User-Agent": "Tokei",
        ]
        if let account = tokens.account_id { headers["ChatGPT-Account-Id"] = account }
        let hint = "Codex rejected the sign-in. Run `codex login`."
        let usage = try await HTTP.json(Usage.self, URLRequest("https://chatgpt.com/backend-api/wham/usage", headers: headers), unauthorizedHint: hint)
        // Banked resets live on their own endpoint; usage still shows if it fails.
        var creditHeaders = headers
        creditHeaders["OpenAI-Beta"] = "codex-1"
        creditHeaders["originator"] = "Codex Desktop"
        let credits = try? await HTTP.json(
            ResetCredits.self, URLRequest("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: creditHeaders), unauthorizedHint: hint
        )
        var snapshot = Self.snapshot(usage: usage, idToken: tokens.id_token)
        snapshot.banked = Self.banked(credits)
        return snapshot
    }

    // MARK: - Parsing

    struct Usage: Decodable {
        struct Window: Decodable {
            var used_percent: Double?
            var reset_at: Double?
            var limit_window_seconds: Double?
        }

        struct RateLimit: Decodable {
            var primary_window: Window?
            var secondary_window: Window?
        }

        struct Credits: Decodable {
            var has_credits: Bool?
            var unlimited: Bool?
            var balance: FlexibleDouble?
        }

        var plan_type: String?
        var rate_limit: RateLimit?
        var credits: Credits?
    }

    struct ResetCredits: Decodable {
        struct Credit: Decodable {
            var status: String?
            var expires_at: String?
        }

        var credits: [Credit]?
    }

    static func banked(_ credits: ResetCredits?, now: Date = .now) -> BankedResets? {
        let available = (credits?.credits ?? []).filter { credit in
            guard credit.status == "available" else { return false }
            return ISODate.parse(credit.expires_at).map { $0 > now } ?? true
        }
        guard !available.isEmpty else { return nil }
        return BankedResets(count: available.count, nextExpiry: available.compactMap { ISODate.parse($0.expires_at) }.min())
    }

    static func snapshot(usage: Usage, idToken: String?, now: Date = .now) -> Snapshot {
        let slots = [("primary", usage.rate_limit?.primary_window), ("secondary", usage.rate_limit?.secondary_window)]
        let windows = slots
            .compactMap { slot, window in window.flatMap { w in w.used_percent.map { (slot, w, $0) } } }
            // The API has been seen returning them swapped; label by length instead of trusting the slot.
            .sorted { ($0.1.limit_window_seconds ?? 0) < ($1.1.limit_window_seconds ?? 0) }
            .map { slot, window, percent in
                let seconds = window.limit_window_seconds
                let isSession = seconds.map { $0 <= 6 * 3600 }
                return UsageWindow(
                    // Unknown length: keep slot-based ids so the two windows stay distinct.
                    id: isSession.map { $0 ? "session" : "weekly" } ?? slot,
                    label: isSession.map { $0 ? "Session" : "Weekly" } ?? slot.capitalized,
                    kind: .primary,
                    used: percent / 100,
                    resetsAt: window.reset_at.map { Date(timeIntervalSince1970: $0) },
                    duration: seconds
                )
            }
        var details: [Detail] = []
        if let credits = usage.credits {
            if credits.unlimited == true {
                details.append(Detail(label: "Credits", value: "Unlimited"))
            } else if credits.has_credits == true, let balance = credits.balance?.value {
                details.append(Detail(label: "Credits", value: balance.formatted(.number.precision(.fractionLength(0 ... 2)))))
            }
        }
        let jwt = idToken.flatMap(JWT.init)
        let email = jwt?.string("email") ?? jwt?.nested("https://api.openai.com/profile", "email")
        let plan = usage.plan_type ?? jwt?.nested("https://api.openai.com/auth", "chatgpt_plan_type")
        return Snapshot(windows: windows, account: Account(user: email, plan: plan?.capitalized), details: details, fetchedAt: now)
    }
}
