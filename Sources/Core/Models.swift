import Foundation

/// CodingKeyRepresentable: persisted dictionaries use readable string keys. Removing a case
/// later still fails decoding of saved state (it is then rebuilt by the next refresh).
enum ProviderID: String, CaseIterable, Codable, CodingKeyRepresentable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Session and weekly/monthly plan limits. Always shown.
        case primary
        /// Per-model limits. Shown when "Model limits" is on.
        case secondary
    }

    var id: String
    var label: String
    var kind: Kind
    /// 0...1, can exceed 1 when over quota.
    var used: Double
    var resetsAt: Date?
    /// Window length, for pace. Optional so older saved state still decodes.
    var duration: TimeInterval?

    /// Past its reset time the saved number is from the previous window.
    func hasReset(now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }
}

struct Account: Codable, Equatable, Sendable {
    /// Email or login.
    var user: String?
    var plan: String?
}

/// Spend, credits, balances. Display-ready because every provider reports money differently.
struct Detail: Codable, Equatable, Sendable {
    var label: String
    var value: String
}

struct Snapshot: Codable, Equatable, Sendable {
    var windows: [UsageWindow]
    var account: Account
    var details: [Detail] = []
    /// One entry per reset kind. Optional so older saved state still decodes; replaces the
    /// old single `banked` value, whose key is now ignored.
    var resets: [BankedResets]?
    var fetchedAt: Date
    /// When the CLI's access token runs out, so the refresher can check right then.
    var signInExpiresAt: Date?
}

/// Free limit resets the plan has banked (Claude "cedar_ember" grants, Codex reset credits).
struct BankedResets: Codable, Equatable, Sendable {
    /// What a Claude reset gives back. Nil for providers that don't say (Codex).
    enum Kind: String, Codable, CaseIterable, Sendable {
        case session, weekly, fable, full

        var noun: String {
            switch self {
            case .session: "5-hour reset"
            case .weekly: "weekly reset"
            case .fable: "Fable reset"
            case .full: "full reset"
            }
        }

        var help: String {
            switch self {
            case .session: "Resets your 5-hour limit now"
            case .weekly: "Resets your weekly limits now"
            case .fable: "Returns what Fable used to your weekly limit"
            case .full: "Resets your session and weekly limits now"
            }
        }
    }

    var kind: Kind?
    var count: Int
    var nextExpiry: Date?
    /// The grant Claude would spend next, when it can be used right now. Nil: no Reset button.
    var grantID: String?

    func text(now: Date) -> String {
        let name = kind?.noun ?? "banked reset"
        let noun = count == 1 ? "1 \(name)" : "\(count) \(name)s"
        guard let nextExpiry else { return noun }
        let when = Calendar.current.isDate(nextExpiry, inSameDayAs: now)
            ? nextExpiry.formatted(date: .omitted, time: .shortened)
            : nextExpiry.formatted(.dateTime.month(.abbreviated).day())
        return "\(noun) · \(count == 1 ? "expires" : "next expires") \(when)"
    }
}

extension [UsageWindow] {
    /// History is keyed by window id, so the first of each id keeps it and repeats get a
    /// "-2", "-3" suffix that no other window uses.
    func withUniqueIDs() -> [UsageWindow] {
        let original = Set(map(\.id))
        var assigned = Set<String>()
        return map { window in
            var copy = window
            var n = 1
            while assigned.contains(copy.id) || (n > 1 && original.contains(copy.id)) {
                n += 1
                copy.id = "\(window.id)-\(n)"
            }
            assigned.insert(copy.id)
            return copy
        }
    }
}

enum ProviderError: Error, Equatable, LocalizedError {
    case notConfigured(String)
    /// The server rejected the sign-in.
    case unauthorized(String)
    /// The saved token's expiry passed. The CLI renews it next time it runs, so no alert.
    case signInExpired(String)
    case keychainLocked
    case keychainBlocked
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case let .notConfigured(hint), let .unauthorized(hint), let .signInExpired(hint): hint
        case .keychainLocked: "Keychain is locked. Refresh to try again."
        case .keychainBlocked: "Couldn't read the Keychain. Refresh to try again."
        case .rateLimited: "Rate limited, retrying later"
        case let .http(code): "Server returned HTTP \(code)"
        case let .badResponse(detail): "Unexpected response: \(detail)"
        }
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// CLI present or sign-in found. Cheap file checks only: runs every refresh tick.
    func isInstalled() -> Bool
    /// Where the CLI writes session logs; writes there mean an agent is working.
    var activityFolder: URL { get }
    /// userInitiated: the user asked (Refresh, Fix, a reset), so a Keychain read may prompt.
    func fetch(userInitiated: Bool) async throws -> Snapshot
}

enum Money {
    static func usd(cents: Double) -> String {
        (cents / 100).formatted(.currency(code: "USD"))
    }
}
