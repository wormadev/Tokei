import Foundation
@testable import Quota
import Testing

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

struct ClaudeParsingTests {
    @Test func `maps five hour and seven day to primary, per model to secondary`() throws {
        let usage = try decode(ClaudeProvider.Usage.self, """
        {"five_hour":{"utilization":42.0,"resets_at":"2026-10-21T15:00:00.123Z"},
         "seven_day":{"utilization":7,"resets_at":"2026-10-25T00:00:00Z"},
         "seven_day_opus":{"utilization":null,"resets_at":null},
         "seven_day_sonnet":{"utilization":12,"resets_at":"2026-10-25T00:00:00Z"},
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1234}}
        """)
        let oauth = ClaudeProvider.Credentials.OAuth(accessToken: "x", expiresAt: nil, subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        let profile = try decode(ClaudeProvider.Profile.self, #"{"account":{"email_address":"a@b.c"}}"#)
        let snapshot = ClaudeProvider.snapshot(usage: usage, profile: profile, oauth: oauth)

        #expect(snapshot.windows.map(\.id) == ["session", "weekly", "sonnet"])
        #expect(snapshot.windows[0].used == 0.42)
        #expect(snapshot.windows[0].resetsAt != nil)
        #expect(snapshot.windows[2].kind == .secondary)
        #expect(snapshot.account == Account(user: "a@b.c", plan: "Max 20x"))
        #expect(snapshot.details.first?.label == "Extra usage")
    }

    @Test func `plan name without multiplier`() {
        #expect(ClaudeProvider.plan(subscription: "pro", tier: "default_claude_pro") == "Pro")
        #expect(ClaudeProvider.plan(subscription: nil, tier: nil) == nil)
    }
}

struct CodexParsingTests {
    @Test func `orders windows by length even when swapped`() throws {
        let usage = try decode(CodexProvider.Usage.self, """
        {"plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":80,"reset_at":1790000000,"limit_window_seconds":604800},
                       "secondary_window":{"used_percent":10,"reset_at":1780000000,"limit_window_seconds":18000}},
         "credits":{"has_credits":true,"unlimited":false,"balance":"12.5"}}
        """)
        let snapshot = CodexProvider.snapshot(usage: usage, idToken: nil)
        #expect(snapshot.windows.map(\.id) == ["session", "weekly"])
        #expect(snapshot.windows[0].used == 0.1)
        #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(snapshot.account.plan == "Plus")
        #expect(snapshot.details == [Detail(label: "Credits", value: 12.5.formatted(.number.precision(.fractionLength(0 ... 2))))])
    }

    @Test func `windows without length or percent stay distinct or are skipped`() throws {
        let usage = try decode(CodexProvider.Usage.self, """
        {"rate_limit":{"primary_window":{"used_percent":5},"secondary_window":{"used_percent":null,"limit_window_seconds":604800}}}
        """)
        let snapshot = CodexProvider.snapshot(usage: usage, idToken: nil)
        #expect(snapshot.windows.map(\.id) == ["primary"])

        let both = try decode(CodexProvider.Usage.self, #"{"rate_limit":{"primary_window":{"used_percent":5},"secondary_window":{"used_percent":9}}}"#)
        #expect(Set(CodexProvider.snapshot(usage: both, idToken: nil).windows.map(\.id)).count == 2)
    }

    @Test func `reads email from id token claims`() {
        let payload = Data(#"{"email":"me@x.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let usage = CodexProvider.Usage(plan_type: nil, rate_limit: nil, credits: nil)
        #expect(CodexProvider.snapshot(usage: usage, idToken: "h.\(payload).s").account.user == "me@x.com")
    }
}

struct CursorParsingTests {
    @Test func `total percent is already a percentage and on demand is cents`() throws {
        let summary = try decode(CursorProvider.Summary.self, """
        {"billingCycleEnd":"2026-11-01T00:00:00.000Z","membershipType":"pro_plus",
         "individualUsage":{"plan":{"enabled":true,"used":1000,"limit":2000,"totalPercentUsed":36.5},
                            "onDemand":{"enabled":true,"used":250,"limit":null}}}
        """)
        let snapshot = CursorProvider.snapshot(summary: summary, email: "c@d.e")
        #expect(snapshot.windows.first?.used == 0.365)
        #expect(snapshot.account.plan == "Pro+")
        #expect(snapshot.details.first?.value == Money.usd(cents: 250))
    }

    @Test func `falls back to used over limit`() throws {
        let summary = try decode(CursorProvider.Summary.self, #"{"individualUsage":{"plan":{"used":500,"limit":2000}}}"#)
        #expect(CursorProvider.snapshot(summary: summary, email: nil).windows.first?.used == 0.25)
    }
}

struct GeminiParsingTests {
    @Test func `keeps tightest bucket per model and inverts remaining fraction`() throws {
        let quota = try decode(GeminiProvider.Quota.self, """
        {"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.9,"resetTime":"2026-10-22T00:00:00Z"},
                    {"modelId":"gemini-2.5-pro","remainingFraction":0.4,"resetTime":"2026-10-22T00:00:00Z"},
                    {"modelId":"gemini-2.5-flash-lite","remainingFraction":1.0},
                    {"modelId":"gemini-2.5-flash","remainingFraction":null}]}
        """)
        let assist = try decode(GeminiProvider.LoadCodeAssist.self, #"{"currentTier":{"id":"free-tier"},"cloudaicompanionProject":{"id":"p1"}}"#)
        let snapshot = GeminiProvider.snapshot(quota: quota, assist: assist, email: "g@x.com", hostedDomain: nil)
        let pro = try #require(snapshot.windows.first { $0.id == "gemini-2.5-pro" })
        #expect(abs(pro.used - 0.6) < 0.0001)
        #expect(pro.kind == .primary)
        #expect(snapshot.windows.first { $0.id == "gemini-2.5-flash-lite" }?.kind == .secondary)
        #expect(snapshot.windows.count == 2)
        #expect(assist.project == "p1")
        #expect(snapshot.account.plan == "Free")
    }

    @Test func `extracts client from cli source`() {
        let source = "const OAUTH_CLIENT_ID = 'abc.apps.googleusercontent.com';\nconst OAUTH_CLIENT_SECRET = \"s3cr3t\";"
        let client = GeminiClientSecret.extract(source)
        #expect(client?.id == "abc.apps.googleusercontent.com")
        #expect(client?.secret == "s3cr3t")
    }
}

struct CopilotParsingTests {
    @Test func `skips unlimited and placeholder quotas`() throws {
        let user = try decode(CopilotProvider.CopilotUser.self, """
        {"copilot_plan":"individual","quota_reset_date":"2026-11-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":"75","percent_remaining":25.0,"unlimited":false},
                            "chat":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":false},
                            "completions":{"unlimited":true}}}
        """)
        let snapshot = CopilotProvider.snapshot(user: user, login: "octocat")
        #expect(snapshot.windows.map(\.id) == ["premium_interactions"])
        #expect(snapshot.windows[0].used == 0.75)
        #expect(snapshot.windows[0].resetsAt != nil)
        #expect(snapshot.account == Account(user: "octocat", plan: "Individual"))
    }
}
