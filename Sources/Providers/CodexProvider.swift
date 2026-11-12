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

    struct SignIn {
        var headers: [String: String]
        var idToken: String?
        var expiresAt: Date?
    }

    static let rejected = "Signed out. Run `codex login` to sign in again."

    static func signIn() throws -> SignIn {
        guard let data = try? Data(contentsOf: authFile),
              let tokens = (try? JSONDecoder().decode(Auth.self, from: data))?.tokens
        else {
            throw ProviderError.notConfigured("Not signed in. Run `codex login` to sign in.")
        }
        let expiresAt = JWT(tokens.access_token)?.expiresAt
        if let expiresAt, expiresAt <= .now {
            throw ProviderError.signInExpired("Sign-in expired")
        }
        var headers = [
            "Authorization": "Bearer \(tokens.access_token)",
            "Accept": "application/json",
            "User-Agent": "Tokei",
        ]
        if let account = tokens.account_id { headers["ChatGPT-Account-Id"] = account }
        return SignIn(headers: headers, idToken: tokens.id_token, expiresAt: expiresAt)
    }

    func fetch(userInitiated: Bool) async throws -> Snapshot {
        let signIn = try Self.signIn()
        let usage = try await HTTP.json(
            Usage.self, URLRequest("https://chatgpt.com/backend-api/wham/usage", headers: signIn.headers), unauthorizedHint: Self.rejected
        )
        // Banked resets live on their own endpoint; usage still shows if it fails.
        let credits = try? await HTTP.json(
            ResetCredits.self, URLRequest("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: Self.creditHeaders(signIn)),
            unauthorizedHint: Self.rejected
        )
        var snapshot = Self.snapshot(usage: usage, idToken: signIn.idToken)
        snapshot.resets = Self.banked(credits).map { [$0] }
        snapshot.signInExpiresAt = signIn.expiresAt
        return snapshot
    }

    /// Spends one reset credit, as the Codex CLI does. The same `requestID` on a retry makes
    /// it the same claim.
    static func redeem(creditID: String, requestID: String) async throws -> RedeemOutcome {
        let signIn = try signIn()
        var request = URLRequest("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume", method: "POST", headers: creditHeaders(signIn))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["redeem_request_id": requestID, "credit_id": creditID])
        struct Consumed: Decodable { var code: String }
        let consumed = try await HTTP.json(Consumed.self, request, unauthorizedHint: rejected)
        return consumeOutcome(consumed.code)
    }

    /// What the reset credit endpoints are seen getting from the Codex app.
    static func creditHeaders(_ signIn: SignIn) -> [String: String] {
        var headers = signIn.headers
        headers["OpenAI-Beta"] = "codex-1"
        headers["originator"] = "Codex Desktop"
        return headers
    }

    static func consumeOutcome(_ code: String) -> RedeemOutcome {
        switch code {
        case "reset", "already_redeemed": RedeemOutcome(message: "Limits refilled.", settled: true, refilled: true)
        case "nothing_to_reset": RedeemOutcome(message: "You're not limited right now, so the reset is still banked.", settled: true)
        case "no_credit": RedeemOutcome(message: "That reset is no longer available.", settled: true)
        default: RedeemOutcome(message: "Codex didn't confirm the reset. Try again in a moment; it won't be spent twice.", settled: false)
        }
    }

    // MARK: - Parsing

    static func windows(_ limit: Usage.RateLimit?, kind: UsageWindow.Kind) -> [UsageWindow] {
        let slots = [("primary", limit?.primary_window), ("secondary", limit?.secondary_window)]
        return slots
            .compactMap { slot, window in window.flatMap { w in w.used_percent.map { (slot, w, $0) } } }
            // The API has been seen returning them swapped; label by length instead of trusting the slot.
            .sorted { ($0.1.limit_window_seconds ?? 0) < ($1.1.limit_window_seconds ?? 0) }
            .map { slot, window, percent in
                let seconds = window.limit_window_seconds
                let isSession = seconds.map { $0 <= 6 * 3600 }
                let label = seconds.map { $0 <= 6 * 3600 ? "Session" : $0 > 8 * 86400 ? "Monthly" : "Weekly" }
                return UsageWindow(
                    // Unknown length: keep slot-based ids so the two windows stay distinct.
                    id: isSession.map { $0 ? "session" : "weekly" } ?? slot,
                    label: label ?? slot.capitalized,
                    kind: kind,
                    used: percent / 100,
                    resetsAt: window.reset_at.map { Date(timeIntervalSince1970: $0) },
                    duration: seconds
                )
            }
    }

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

        /// Per-model limits, e.g. a Spark model with its own session and weekly windows.
        struct Additional: Decodable {
            var limit_name: String?
            var rate_limit: RateLimit?
        }

        var plan_type: String?
        var rate_limit: RateLimit?
        /// Extra data: an unexpected shape here must not cost the main limits.
        var additional_rate_limits: Lossy<[Additional]>?
        var credits: Credits?
    }

    struct ResetCredits: Decodable {
        struct Credit: Decodable {
            var id: String?
            var status: String?
            var reset_type: String?
            var expires_at: String?
        }

        var credits: [Credit]?
    }

    /// The credit to spend is the one expiring soonest.
    static func banked(_ credits: ResetCredits?, now: Date = .now) -> BankedResets? {
        let available = (credits?.credits ?? []).filter { credit in
            guard credit.status == "available", credit.reset_type.map({ $0 == "codex_rate_limits" }) ?? true else { return false }
            return ISODate.parse(credit.expires_at).map { $0 > now } ?? true
        }
        guard !available.isEmpty else { return nil }
        let next = available.min { (ISODate.parse($0.expires_at) ?? .distantFuture) < (ISODate.parse($1.expires_at) ?? .distantFuture) }
        return BankedResets(
            count: available.count, nextExpiry: available.compactMap { ISODate.parse($0.expires_at) }.min(), grantID: next?.id
        )
    }

    static func snapshot(usage: Usage, idToken: String?, now: Date = .now) -> Snapshot {
        var windows = Self.windows(usage.rate_limit, kind: .primary)
        for additional in usage.additional_rate_limits?.value ?? [] {
            guard let name = additional.limit_name, !name.isEmpty else { continue }
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            windows += Self.windows(additional.rate_limit, kind: .secondary).map { window in
                var window = window
                window.id = "\(slug)-\(window.id)"
                window.label = "\(name) \(window.label.lowercased())"
                return window
            }
        }
        windows = windows.withUniqueIDs()

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
