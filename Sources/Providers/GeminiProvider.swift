import Foundation

struct GeminiProvider: UsageProvider {
    let id = ProviderID.gemini

    static var geminiDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini")
    }

    static var credsFile: URL { geminiDir.appending(path: "oauth_creds.json") }

    func fetch() async throws -> Snapshot {
        guard let data = try? Data(contentsOf: Self.credsFile),
              var creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ProviderError.notConfigured("Run `gemini` and sign in with Google.")
        }
        if let type = Self.selectedAuthType(), type.contains("api-key") || type == "vertex-ai" {
            throw ProviderError.notConfigured("Gemini CLI uses an API key; quotas need Google sign-in.")
        }
        let expiry = (creds["expiry_date"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        if creds["access_token"] as? String == nil || expiry <= .now {
            creds = try await Self.refresh(creds)
        }
        guard let token = creds["access_token"] as? String else {
            throw ProviderError.unauthorized("Run `gemini` and sign in again.")
        }
        let headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json"]
        let hint = "Google rejected the sign-in. Run `gemini` and sign in again."

        var load = URLRequest("https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", method: "POST", headers: headers)
        load.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        let assist = try? await HTTP.json(LoadCodeAssist.self, load, unauthorizedHint: hint)

        var quota = URLRequest("https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota", method: "POST", headers: headers)
        let body = assist?.project.map { ["project": $0] } ?? [:]
        quota.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await HTTP.json(Quota.self, quota, unauthorizedHint: hint)

        let jwt = (creds["id_token"] as? String).flatMap(JWT.init)
        return Self.snapshot(quota: response, assist: assist, email: jwt?.string("email"), hostedDomain: jwt?.string("hd"))
    }

    static func selectedAuthType() -> String? {
        guard let data = try? Data(contentsOf: geminiDir.appending(path: "settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let security = settings["security"] as? [String: Any]
        return (security?["auth"] as? [String: Any])?["selectedType"] as? String
    }

    // MARK: - Token refresh

    /// Google refresh tokens don't rotate, so refreshing here doesn't disturb the CLI.
    /// The new access token is written back so the CLI benefits too.
    static func refresh(_ creds: [String: Any]) async throws -> [String: Any] {
        guard let refreshToken = creds["refresh_token"] as? String else {
            throw ProviderError.unauthorized("Run `gemini` and sign in again.")
        }
        guard let client = GeminiClientSecret.find() else {
            throw ProviderError.notConfigured("Install gemini-cli (it holds the OAuth client Quota needs to refresh).")
        }
        var request = URLRequest("https://oauth2.googleapis.com/token", method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"])
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "client_secret", value: client.secret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let data = try await HTTP.data(request, unauthorizedHint: "Run `gemini` and sign in again.")
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = response["access_token"] as? String
        else { throw ProviderError.badResponse("token refresh") }

        var updated = creds
        updated["access_token"] = access
        updated["expiry_date"] = (Date.now.timeIntervalSince1970 + ((response["expires_in"] as? Double) ?? 3600)) * 1000
        if let id = response["id_token"] { updated["id_token"] = id }
        if let out = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted]) {
            try? out.write(to: credsFile, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credsFile.path)
        }
        return updated
    }

    // MARK: - Parsing

    struct LoadCodeAssist: Decodable {
        struct Tier: Decodable {
            var id: String?
            var name: String?
        }

        var currentTier: Tier?
        var paidTier: Tier?
        var project: String?

        enum CodingKeys: String, CodingKey { case currentTier, paidTier, cloudaicompanionProject }

        private struct ProjectObject: Decodable {
            var id: String?
            var projectId: String?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currentTier = try? c.decode(Tier.self, forKey: .currentTier)
            paidTier = try? c.decode(Tier.self, forKey: .paidTier)
            if let string = try? c.decode(String.self, forKey: .cloudaicompanionProject) {
                project = string
            } else if let object = try? c.decode(ProjectObject.self, forKey: .cloudaicompanionProject) {
                project = object.id ?? object.projectId
            }
        }
    }

    struct Quota: Decodable {
        struct Bucket: Decodable {
            var modelId: String?
            var remainingFraction: Double?
            var resetTime: String?
        }

        var buckets: [Bucket]?
    }

    static func snapshot(quota: Quota, assist: LoadCodeAssist?, email: String?, hostedDomain: String?, now: Date = .now) -> Snapshot {
        // Several buckets per model are possible; the tightest one is what limits you.
        var tightest: [String: Quota.Bucket] = [:]
        for bucket in quota.buckets ?? [] {
            guard let model = bucket.modelId, let remaining = bucket.remainingFraction else { continue }
            if remaining < (tightest[model]?.remainingFraction ?? .infinity) { tightest[model] = bucket }
        }
        let windows = tightest.values
            .sorted { ($0.modelId ?? "") < ($1.modelId ?? "") }
            .map { bucket in
                let model = bucket.modelId ?? ""
                let isLite = model.contains("lite")
                return UsageWindow(
                    id: model,
                    label: model.replacingOccurrences(of: "gemini-", with: "").capitalized,
                    kind: model.contains("pro") || (model.contains("flash") && !isLite) ? .primary : .secondary,
                    used: 1 - (bucket.remainingFraction ?? 1),
                    resetsAt: ISODate.parse(bucket.resetTime)
                )
            }
        return Snapshot(windows: windows, account: Account(user: email, plan: plan(assist: assist, hostedDomain: hostedDomain)), fetchedAt: now)
    }

    static func plan(assist: LoadCodeAssist?, hostedDomain: String?) -> String? {
        if let paid = assist?.paidTier?.name { return paid }
        switch assist?.currentTier?.id {
        case "standard-tier": return "Paid"
        case "free-tier": return hostedDomain == nil ? "Free" : "Workspace"
        case "legacy-tier": return "Legacy"
        default: return nil
        }
    }
}

/// gemini-cli ships its OAuth client id/secret in its JS bundle; Google requires them to refresh.
enum GeminiClientSecret {
    struct Client { let id: String; let secret: String }

    static func find() -> Client? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["GEMINI_OAUTH_CLIENT_ID"], let secret = env["GEMINI_OAUTH_CLIENT_SECRET"] {
            return Client(id: id, secret: secret)
        }
        guard let root = packageRoot() else { return nil }
        let candidates = [
            "dist/src/code_assist/oauth2.js",
            "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ].map { root.appending(path: $0) }
        let bundle = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "bundle"), includingPropertiesForKeys: nil)) ?? []
        for file in candidates + bundle.filter({ $0.pathExtension == "js" }) {
            if let client = (try? String(contentsOf: file, encoding: .utf8)).flatMap(extract) { return client }
        }
        return nil
    }

    static func extract(_ source: String) -> Client? {
        func match(_ name: String) -> String? {
            guard let regex = try? Regex("\(name)\\s*=\\s*['\"]([^'\"]+)['\"]"),
                  let found = source.firstMatch(of: regex), let value = found.output[1].substring
            else { return nil }
            return String(value)
        }
        guard let id = match("OAUTH_CLIENT_ID"), let secret = match("OAUTH_CLIENT_SECRET") else { return nil }
        return Client(id: id, secret: secret)
    }

    /// Resolves the `gemini` executable's symlinks and walks up to the @google/gemini-cli package.
    static func packageRoot() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = path + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.local/bin", "\(home)/.bun/bin"]
        for dir in dirs {
            let binary = URL(fileURLWithPath: dir).appending(path: "gemini")
            guard FileManager.default.fileExists(atPath: binary.path) else { continue }
            var url = binary.resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0 ..< 8 {
                let manifest = url.appending(path: "package.json")
                if let data = try? Data(contentsOf: manifest), String(decoding: data, as: UTF8.self).contains("\"@google/gemini-cli\"") {
                    return url
                }
                let nested = url.appending(path: "lib/node_modules/@google/gemini-cli")
                if FileManager.default.fileExists(atPath: nested.appending(path: "package.json").path) { return nested }
                url.deleteLastPathComponent()
            }
        }
        return nil
    }
}
