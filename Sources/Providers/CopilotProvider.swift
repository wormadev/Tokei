import Foundation

struct CopilotProvider: UsageProvider {
    let id = ProviderID.copilot
    static let keychainService = "com.wormadev.Quota"
    static let keychainAccount = "copilot-github-token"

    static var token: String? {
        Keychain.read(service: keychainService, account: keychainAccount, allowUI: false).map { String(decoding: $0, as: UTF8.self) }
    }

    func fetch() async throws -> Snapshot {
        guard let token = Self.token else {
            throw ProviderError.needsConnect("Sign in with GitHub to see your Copilot quota.")
        }
        let headers = [
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        ]
        let hint = "GitHub rejected the token. Sign out in Settings, then sign in again."
        let user = try await HTTP.json(CopilotUser.self, URLRequest("https://api.github.com/copilot_internal/user", headers: headers), unauthorizedHint: hint)
        let login = try? await HTTP.json(GitHubUser.self, URLRequest("https://api.github.com/user", headers: headers), unauthorizedHint: hint)
        return Self.snapshot(user: user, login: login?.login)
    }

    // MARK: - Parsing

    struct CopilotUser: Decodable {
        struct Quota: Decodable {
            var entitlement: FlexibleDouble?
            var remaining: FlexibleDouble?
            var percent_remaining: FlexibleDouble?
            var unlimited: Bool?
        }

        var copilot_plan: String?
        var quota_reset_date: String?
        var quota_snapshots: [String: Quota]?
    }

    struct GitHubUser: Decodable {
        var login: String
    }

    static func snapshot(user: CopilotUser, login: String?, now: Date = .now) -> Snapshot {
        let resets = ISODate.parse(user.quota_reset_date)
        let entries: [(String, String)] = [("premium_interactions", "Premium requests"), ("chat", "Chat")]
        let windows = entries.compactMap { key, label -> UsageWindow? in
            guard let quota = user.quota_snapshots?[key], quota.unlimited != true else { return nil }
            let entitlement = quota.entitlement?.value ?? 0
            let remaining = quota.remaining?.value ?? 0
            // Business seats report zeroed placeholders; they are not real limits.
            if entitlement == 0, remaining == 0 { return nil }
            let percentRemaining = quota.percent_remaining?.value ?? (entitlement > 0 ? remaining / entitlement * 100 : 100)
            return UsageWindow(id: key, label: label, kind: .primary, used: max(0, 100 - percentRemaining) / 100, resetsAt: resets)
        }
        return Snapshot(windows: windows, account: Account(user: login, plan: user.copilot_plan?.capitalized), fetchedAt: now)
    }
}

/// GitHub OAuth device flow with the VS Code Copilot client id, the only one
/// `copilot_internal/user` is known to accept.
enum CopilotDeviceFlow {
    static let clientID = "Iv1.b507a08c87ecfe98"

    struct Code: Decodable, Sendable {
        var device_code: String
        var user_code: String
        var verification_uri: String
        var interval: Double?
        var expires_in: Double?
    }

    static func start() async throws -> Code {
        var request = URLRequest("https://github.com/login/device/code", method: "POST", headers: [
            "Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded",
        ])
        request.httpBody = Data("client_id=\(clientID)&scope=read:user".utf8)
        return try await HTTP.json(Code.self, request, unauthorizedHint: "GitHub refused the sign-in request.")
    }

    /// Polls until the user approves in the browser, then stores the token.
    static func complete(_ code: Code) async throws {
        struct Response: Decodable {
            var access_token: String?
            var error: String?
        }
        var interval = code.interval ?? 5
        let deadline = Date.now.addingTimeInterval(code.expires_in ?? 900)
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            var request = URLRequest("https://github.com/login/oauth/access_token", method: "POST", headers: [
                "Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded",
            ])
            request.httpBody = Data("client_id=\(clientID)&device_code=\(code.device_code)&grant_type=urn:ietf:params:oauth:grant-type:device_code".utf8)
            let response = try await HTTP.json(Response.self, request, unauthorizedHint: "GitHub refused the sign-in.")
            if let token = response.access_token {
                guard Keychain.write(Data(token.utf8), service: CopilotProvider.keychainService, account: CopilotProvider.keychainAccount) else {
                    throw ProviderError.notConfigured("Couldn't save the GitHub token to the Keychain.")
                }
                return
            }
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            default: throw ProviderError.unauthorized("GitHub sign-in failed: \(response.error ?? "unknown error")")
            }
        }
        throw ProviderError.unauthorized("GitHub sign-in timed out.")
    }

    static func signOut() {
        Keychain.delete(service: CopilotProvider.keychainService, account: CopilotProvider.keychainAccount)
    }
}
