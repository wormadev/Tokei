import Foundation
import SQLite3

struct CursorProvider: UsageProvider {
    let id = ProviderID.cursor

    static var stateDB: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func fetch() async throws -> Snapshot {
        guard let token = Self.readAccessToken(), let jwt = JWT(token), let sub = jwt.string("sub") else {
            throw ProviderError.notConfigured("Open Cursor and sign in.")
        }
        if let exp = jwt.expiresAt, exp <= .now {
            throw ProviderError.unauthorized("Sign-in expired. Open Cursor to refresh it.")
        }
        let userID = sub.split(separator: "|").last.map(String.init) ?? sub
        let cookie = "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"
        let headers = ["Accept": "application/json", "Cookie": cookie]
        let hint = "Cursor rejected the sign-in. Open Cursor and sign in again."
        let summary = try await HTTP.json(
            Summary.self, URLRequest("https://cursor.com/api/usage-summary", headers: headers), unauthorizedHint: hint
        )
        let me = try? await HTTP.json(Me.self, URLRequest("https://cursor.com/api/auth/me", headers: headers), unauthorizedHint: hint)
        return Self.snapshot(summary: summary, email: me?.email ?? jwt.string("email"))
    }

    /// Cursor.app's own SQLite store. Read-only, so it never contends with a running Cursor.
    static func readAccessToken() -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(stateDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian)
        return text?.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
    }

    // MARK: - Parsing

    struct Summary: Decodable {
        struct Bucket: Decodable {
            var enabled: Bool?
            var used: Double?
            var limit: Double?
            var totalPercentUsed: Double?
        }

        struct Individual: Decodable {
            var plan: Bucket?
            var onDemand: Bucket?
        }

        var billingCycleEnd: String?
        var membershipType: String?
        var individualUsage: Individual?
    }

    struct Me: Decodable {
        var email: String?
    }

    static func snapshot(summary: Summary, email: String?, now: Date = .now) -> Snapshot {
        var windows: [UsageWindow] = []
        let plan = summary.individualUsage?.plan
        // totalPercentUsed is already a percentage (0.36 means 0.36%).
        let fraction = plan?.totalPercentUsed.map { $0 / 100 }
            ?? plan.flatMap { bucket in bucket.used.flatMap { used in bucket.limit.map { used / max($0, 1) } } }
        if let fraction {
            windows.append(UsageWindow(id: "plan", label: "Monthly", kind: .primary, used: fraction, resetsAt: ISODate.parse(summary.billingCycleEnd)))
        }
        var details: [Detail] = []
        if let onDemand = summary.individualUsage?.onDemand, onDemand.enabled == true, let used = onDemand.used {
            let limit = onDemand.limit.map { " of \(Money.usd(cents: $0))" } ?? ""
            details.append(Detail(label: "On-demand", value: Money.usd(cents: used) + limit))
        }
        return Snapshot(
            windows: windows,
            account: Account(user: email, plan: summary.membershipType.map(planName)),
            details: details,
            fetchedAt: now
        )
    }

    static func planName(_ membership: String) -> String {
        switch membership {
        case "pro", "pro_student": "Pro"
        case "pro_plus": "Pro+"
        case "free_trial": "Pro Trial"
        case "express": "Start"
        default: membership.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
