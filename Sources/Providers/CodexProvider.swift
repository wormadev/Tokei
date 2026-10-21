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
            "User-Agent": "Quota",
        ]
        if let account = tokens.account_id { headers["ChatGPT-Account-Id"] = account }
        let usage = try await HTTP.json(
            Usage.self,
            URLRequest("https://chatgpt.com/backend-api/wham/usage", headers: headers),
            unauthorizedHint: "Codex rejected the sign-in. Run `codex login`."
        )
        return Self.snapshot(usage: usage, idToken: tokens.id_token)
    }

    // MARK: - Parsing

    struct Usage: Decodable {
        struct Window: Decodable {
            var used_percent: Double
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

    static func snapshot(usage: Usage, idToken: String?, now: Date = .now) -> Snapshot {
        let windows = [usage.rate_limit?.primary_window, usage.rate_limit?.secondary_window]
            .compactMap(\.self)
            // The API has been seen returning them swapped; order by length instead of trusting slot.
            .sorted { ($0.limit_window_seconds ?? 0) < ($1.limit_window_seconds ?? 0) }
            .map { window in
                let isSession = (window.limit_window_seconds ?? 0) <= 6 * 3600
                return UsageWindow(
                    id: isSession ? "session" : "weekly",
                    label: isSession ? "Session" : "Weekly",
                    kind: .primary,
                    used: window.used_percent / 100,
                    resetsAt: window.reset_at.map { Date(timeIntervalSince1970: $0) }
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
