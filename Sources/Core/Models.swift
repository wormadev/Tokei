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
    /// Optional so older saved state still decodes.
    var banked: BankedResets?
    var fetchedAt: Date
}

/// Free limit resets the plan has banked (Claude "cedar_ember" grants, Codex reset credits).
struct BankedResets: Codable, Equatable, Sendable {
    var count: Int
    var nextExpiry: Date?
    /// The grant Claude would spend next, when it can be used right now. Nil: no Reset button.
    var grantID: String?

    func text(now: Date) -> String {
        let noun = count == 1 ? "1 banked reset" : "\(count) banked resets"
        guard let nextExpiry else { return noun }
        let when = Calendar.current.isDate(nextExpiry, inSameDayAs: now)
            ? nextExpiry.formatted(date: .omitted, time: .shortened)
            : nextExpiry.formatted(.dateTime.month(.abbreviated).day())
        return "\(noun) · \(count == 1 ? "expires" : "next expires") \(when)"
    }
}

enum ProviderError: Error, Equatable, LocalizedError {
    case notConfigured(String)
    /// Fixable with the card's Connect / Sign in button.
    case needsConnect(String)
    case unauthorized(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case let .notConfigured(hint), let .needsConnect(hint), let .unauthorized(hint): hint
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
    func fetch() async throws -> Snapshot
}

enum Money {
    static func usd(cents: Double) -> String {
        (cents / 100).formatted(.currency(code: "USD"))
    }
}
