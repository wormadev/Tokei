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
    var fetchedAt: Date
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
    func fetch() async throws -> Snapshot
}

enum Money {
    static func usd(cents: Double) -> String {
        (cents / 100).formatted(.currency(code: "USD"))
    }
}
