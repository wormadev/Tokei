import Foundation
@testable import Tokei
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

        #expect(snapshot.windows.map(\.id) == ["session", "weekly", "weekly-sonnet"])
        #expect(snapshot.windows[0].used == 0.42)
        #expect(snapshot.windows[0].resetsAt != nil)
        #expect(snapshot.windows[2].kind == .secondary)
        #expect(snapshot.account == Account(user: "a@b.c", plan: "Ultra"))
        #expect(snapshot.details.first?.label == "Extra usage")
    }

    @Test func `prefers the limits array, with model scoped weekly as secondary, and adds the breakdown`() throws {
        let usage = try decode(ClaudeProvider.Usage.self, """
        {"five_hour":{"utilization":99,"resets_at":null},"seven_day_opus":null,
         "limits":[{"kind":"session","percent":12,"resets_at":"2026-10-21T20:39:59.592170+00:00","scope":null},
                   {"kind":"weekly_all","percent":43,"resets_at":"2026-10-24T20:59:59.592194+00:00"},
                   {"kind":"weekly_scoped","percent":5,"resets_at":"2026-10-24T21:00:00+00:00",
                    "scope":{"model":{"id":null,"display_name":"Example"},"surface":null}},
                   {"kind":"something_new","percent":1}],
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null},
         "seven_day_breakdown":{"rows":[{"key":"claude_code","display_name":"Claude Code","percent":100},
                                        {"key":"chat","display_name":"Chats","percent":0}]}}
        """)
        let oauth = ClaudeProvider.Credentials.OAuth(accessToken: "x", expiresAt: nil, subscriptionType: "pro", rateLimitTier: nil)
        let snapshot = ClaudeProvider.snapshot(usage: usage, profile: nil, oauth: oauth)
        #expect(snapshot.windows.map(\.id) == ["session", "weekly", "weekly-example"])
        #expect(snapshot.windows[0].used == 0.12)
        #expect(snapshot.windows[0].resetsAt != nil)
        #expect(snapshot.windows[2].label == "Example weekly")
        #expect(snapshot.windows[2].kind == .secondary)
        #expect(snapshot.details == [Detail(label: "Claude Code this week", value: "100%")])
    }

    @Test func `repeated limits get distinct ids, unique ones keep theirs`() throws {
        let usage = try decode(ClaudeProvider.Usage.self, """
        {"limits":[{"kind":"session","percent":1},
                   {"kind":"weekly_scoped","percent":2},
                   {"kind":"weekly_scoped","percent":3,"scope":{"model":{"display_name":"Model"}}},
                   {"kind":"weekly_scoped","percent":4,"scope":{"model":{"display_name":"Opus"}}}]}
        """)
        let oauth = ClaudeProvider.Credentials.OAuth(accessToken: "x", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil)
        let ids = ClaudeProvider.snapshot(usage: usage, profile: nil, oauth: oauth).windows.map(\.id)
        #expect(ids == ["session", "weekly-model", "weekly-model-2", "weekly-opus"])
    }

    @Test func `a missing expiry is not treated as expired`() throws {
        let credentials = try decode(ClaudeProvider.Credentials.self, #"{"claudeAiOauth":{"accessToken":"x"}}"#)
        #expect(!credentials.isExpired)
        let expired = try decode(ClaudeProvider.Credentials.self, #"{"claudeAiOauth":{"accessToken":"x","expiresAt":1000}}"#)
        #expect(expired.isExpired)
    }

    @Test func `a session without a number is not started, a weekly-only plan gets no session, percent may be a string`() throws {
        let oauth = ClaudeProvider.Credentials.OAuth(accessToken: "x", expiresAt: nil, subscriptionType: "max", rateLimitTier: nil)
        let started = try decode(ClaudeProvider.Usage.self, """
        {"limits":[{"kind":"session","percent":null,"resets_at":null},{"kind":"weekly_all","percent":"47","resets_at":null}]}
        """)
        let windows = ClaudeProvider.snapshot(usage: started, profile: nil, oauth: oauth).windows
        #expect(windows.map(\.id) == ["session", "weekly"])
        #expect(windows[0].used == 0)
        #expect(windows[0].resetsAt == nil)
        #expect(windows[1].used == 0.47)

        let weeklyOnly = try decode(ClaudeProvider.Usage.self, #"{"limits":[{"kind":"weekly_all","percent":10}]}"#)
        #expect(ClaudeProvider.snapshot(usage: weeklyOnly, profile: nil, oauth: oauth).windows.map(\.id) == ["weekly"])

        let legacy = try decode(ClaudeProvider.Usage.self, #"{"five_hour":{"utilization":null,"resets_at":null},"seven_day":{"utilization":5}}"#)
        #expect(ClaudeProvider.snapshot(usage: legacy, profile: nil, oauth: oauth).windows.map(\.id) == ["session", "weekly"])
    }

    @Test func `version folder names are recognized`() {
        #expect(ClaudeProvider.isVersion("2.1.306"))
        #expect(!ClaudeProvider.isVersion("claude"))
        #expect(!ClaudeProvider.isVersion("cli.js"))
    }

    @Test func `plan name without multiplier`() {
        #expect(ClaudeProvider.plan(subscription: "pro", tier: "default_claude_pro") == "Pro")
        #expect(ClaudeProvider.plan(subscription: nil, tier: nil) == nil)
    }

    @Test func `max tiers use the new plan names`() {
        #expect(ClaudeProvider.plan(subscription: "max", tier: "default_claude_max_5x") == "Max")
        #expect(ClaudeProvider.plan(subscription: "max", tier: "default_claude_max_20x") == "Ultra")
        #expect(ClaudeProvider.plan(subscription: "ultra", tier: nil) == "Ultra")
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

    @Test func `a 30 day window is monthly and keeps a distinct id`() throws {
        let usage = try decode(CodexProvider.Usage.self, """
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":2592000},
                       "secondary_window":{"used_percent":9,"limit_window_seconds":604800}}}
        """)
        let windows = CodexProvider.snapshot(usage: usage, idToken: nil).windows
        #expect(windows.map(\.id) == ["weekly", "weekly-2"])
        #expect(windows.map(\.label) == ["Weekly", "Monthly"])
    }

    @Test func `per-model limits become secondary windows, and a bad shape there is ignored`() throws {
        let usage = try decode(CodexProvider.Usage.self, """
        {"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_at":1800000000}},
         "additional_rate_limits":[{"limit_name":"GPT Spark","rate_limit":{
            "primary_window":{"used_percent":5,"limit_window_seconds":18000},
            "secondary_window":{"used_percent":40,"limit_window_seconds":604800}}}]}
        """)
        let windows = CodexProvider.snapshot(usage: usage, idToken: nil).windows
        #expect(windows.map(\.id) == ["session", "gpt-spark-session", "gpt-spark-weekly"])
        #expect(windows.map(\.label) == ["Session", "GPT Spark session", "GPT Spark weekly"])
        #expect(windows[2].kind == .secondary)

        let odd = try decode(CodexProvider.Usage.self, #"{"rate_limit":{"primary_window":{"used_percent":20}},"additional_rate_limits":{"oops":1}}"#)
        #expect(CodexProvider.snapshot(usage: odd, idToken: nil).windows.count == 1)
    }

    @Test func `reads email from id token claims`() {
        let payload = Data(#"{"email":"me@x.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let usage = CodexProvider.Usage(plan_type: nil, rate_limit: nil, credits: nil)
        #expect(CodexProvider.snapshot(usage: usage, idToken: "h.\(payload).s").account.user == "me@x.com")
    }
}

struct PaceTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func window(used: Double, elapsed: TimeInterval, duration: TimeInterval = 7 * 86400) -> UsageWindow {
        UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: used, resetsAt: now.addingTimeInterval(duration - elapsed), duration: duration)
    }

    @Test func `half the week gone with 40 percent used is 10 percent in reserve and lasts`() throws {
        let pace = try #require(Pace(window: window(used: 0.4, elapsed: 3.5 * 86400), now: now))
        #expect(abs(pace.delta + 0.1) < 0.0001)
        #expect(pace.headline(now: now) == "10% in reserve · Lasts until reset")
    }

    @Test func `using faster than the spread forecasts running out`() throws {
        // 80% used after 2 of 5 hours: 0.4/h, the remaining 20% lasts 30 minutes.
        let pace = try #require(Pace(window: window(used: 0.8, elapsed: 2 * 3600, duration: 5 * 3600), now: now))
        #expect(pace.runsOut)
        #expect(pace.runsOutIn.map { abs($0 - 1800) < 1 } == true)
        #expect(pace.headline(now: now) == "40% in deficit · Runs out in 30m")
    }

    @Test func `no pace without a reset time, early in the window, or with an unknown length`() {
        #expect(Pace(window: window(used: 0.01, elapsed: 0.02 * 7 * 86400), now: now) == nil)
        var noReset = window(used: 0.4, elapsed: 86400)
        noReset.resetsAt = nil
        #expect(Pace(window: noReset, now: now) == nil)
        var noLength = window(used: 0.4, elapsed: 86400)
        noLength.duration = nil
        #expect(Pace(window: noLength, now: now) == nil)
    }

    @Test func `within two points is on pace`() throws {
        let pace = try #require(Pace(window: window(used: 0.49, elapsed: 3.5 * 86400), now: now))
        #expect(pace.isOnTrack)
        #expect(pace.headline(now: now) == "On pace · Lasts until reset")
    }
}

struct BankedResetTests {
    private let now = ISODate.parse("2026-10-21T12:00:00Z")!

    @Test func `claude counts live grants only and finds the soonest expiry`() throws {
        let cedar = try decode(ClaudeProvider.CedarEmber.self, """
        {"eligible":true,"next_grant_id":"g1","grants":[
          {"id":"g1","resets_left":2,"resets_total":3,"starts_at":"2026-10-01T00:00:00Z","ends_at":"2026-11-03T00:00:00Z","paused":false,"usable_now":true},
          {"id":"g2","resets_left":1,"starts_at":null,"ends_at":null,"paused":false},
          {"id":"g3","resets_left":5,"ends_at":"2026-10-01T00:00:00Z","paused":false},
          {"id":"g4","resets_left":5,"paused":true},
          {"id":"g5","resets_left":0}]}
        """)
        let banked = ClaudeProvider.banked(cedar, now: now)
        #expect(banked == [BankedResets(kind: .full, count: 3, nextExpiry: ISODate.parse("2026-11-03T00:00:00Z"), grantID: "g1")])
        #expect(ClaudeProvider.banked(try decode(ClaudeProvider.CedarEmber.self, #"{"eligible":false,"grants":[{"resets_left":1}]}"#), now: now).isEmpty)
        #expect(ClaudeProvider.banked(nil, now: now).isEmpty)
    }

    @Test func `claude groups grants by kind, fable apart, each with its own grant to spend`() throws {
        let cedar = try decode(ClaudeProvider.CedarEmber.self, """
        {"eligible":true,"next_grant_id":"weekly_a","grants":[
          {"id":"weekly_a","resets_left":1,"clears":["seven_day"],"usable_now":true},
          {"id":"fable_a","resets_left":1,"clears":["seven_day_overage_included"],"gives_back_weekly":true,"usable_now":true,"ends_at":"2027-03-09T07:59:00Z"},
          {"id":"fable_b","resets_left":2,"gives_back_weekly":true,"type":"weekly","usable_now":true},
          {"id":"session_a","resets_left":1,"type":"session","usable_now":true},
          {"id":"full_a","resets_left":4,"clears":["five_hour","seven_day"],"usable_now":true}]}
        """)
        let banked = ClaudeProvider.banked(cedar, now: now)
        #expect(banked.map(\.kind) == [.session, .weekly, .fable, .full])
        #expect(banked.map(\.count) == [1, 1, 3, 4])
        #expect(banked.map(\.grantID) == ["session_a", "weekly_a", "fable_a", "full_a"])
        #expect(banked[2].nextExpiry == ISODate.parse("2027-03-09T07:59:00Z"))
    }

    @Test func `claude grant kinds follow the CLI`() throws {
        let cedar = try decode(ClaudeProvider.CedarEmber.self, """
        {"grants":[
          {"clears":["five_hour"]},
          {"clears":["seven_day","seven_day_opus"]},
          {"clears":["five_hour","seven_day"]},
          {"clears":[]},
          {},
          {"clears":["five_hour"],"type":"weekly"},
          {"clears":["five_hour"],"type":"something_new"},
          {"clears":["five_hour"],"type":"session","gives_back_weekly":true}]}
        """)
        #expect(cedar.grants?.map(\.kind) == [.session, .weekly, .full, .full, .full, .weekly, .session, .fable])
    }

    @Test func `claude groups grants per kind in a fixed order, each with its own grant`() throws {
        let cedar = try decode(ClaudeProvider.CedarEmber.self, """
        {"eligible":true,"grants":[
          {"id":"f1","resets_left":1,"gives_back_weekly":true,"usable_now":false,"ends_at":"2026-11-05T00:00:00Z"},
          {"id":"f2","resets_left":1,"gives_back_weekly":true,"usable_now":true,"ends_at":"2026-11-03T00:00:00Z"},
          {"id":"w1","resets_left":1,"clears":["seven_day"],"usable_now":true,"ends_at":"2026-10-21T14:00:00Z"},
          {"id":"s1","resets_left":0,"clears":["five_hour"],"usable_now":true}]}
        """)
        let banked = ClaudeProvider.banked(cedar, now: now)
        #expect(banked.map(\.kind) == [.weekly, .fable])
        #expect(banked[0] == BankedResets(kind: .weekly, count: 1, nextExpiry: ISODate.parse("2026-10-21T14:00:00Z"), grantID: "w1"))
        #expect(banked[1] == BankedResets(kind: .fable, count: 2, nextExpiry: ISODate.parse("2026-11-03T00:00:00Z"), grantID: "f2"))
        #expect(banked[1].detail(now: now).hasPrefix("2 left · next expires "))
        #expect(banked[0].detail(now: now).hasPrefix("1 left · expires "))
    }

    @Test func `a malformed grant is skipped and a malformed cedar_ember never fails usage`() throws {
        let cedar = try decode(ClaudeProvider.CedarEmber.self, """
        {"eligible":true,"grants":[
          {"id":"bad","resets_left":"lots","clears":["five_hour"]},
          7, null,
          {"id":"ok","resets_left":1,"clears":["five_hour"],"usable_now":true}]}
        """)
        #expect(cedar.grants?.map(\.id) == ["ok"])
        #expect(ClaudeProvider.banked(cedar, now: now).map(\.grantID) == ["ok"])

        for cedar in [#""yes""#, #"{"eligible":"maybe","grants":{"id":1}}"#, "[1,2]"] {
            let usage = try decode(ClaudeProvider.Usage.self, #"{"five_hour":{"utilization":10},"cedar_ember":\#(cedar)}"#)
            #expect(usage.five_hour?.utilization == 10)
            #expect(ClaudeProvider.banked(usage.cedar_ember, now: now).isEmpty)
        }
    }

    @Test func `no reset button when the grant can't be used now`() throws {
        let cedar = try decode(ClaudeProvider.CedarEmber.self, #"{"eligible":true,"grants":[{"id":"g1","resets_left":1,"paused":false,"usable_now":false}]}"#)
        let banked = try #require(ClaudeProvider.banked(cedar, now: now).first)
        #expect(banked.count == 1)
        #expect(banked.grantID == nil)
        #expect(ClaudeProvider.claimOutcome("reset") == RedeemOutcome(message: "Limits refilled.", settled: true, refilled: true))
        #expect(ClaudeProvider.claimOutcome("cooldown").settled)
        #expect(!ClaudeProvider.claimOutcome("unavailable").settled)
    }

    @Test func `saved state with the old single banked value still decodes`() throws {
        let json = #"{"windows":[],"account":{},"details":[],"banked":{"count":2},"fetchedAt":0}"#
        let snapshot = try decode(Snapshot.self, json)
        #expect(snapshot.resets == nil)
    }

    @Test func `codex counts available unexpired credits`() throws {
        let credits = try decode(CodexProvider.ResetCredits.self, """
        {"credits":[{"id":"a","status":"available","expires_at":"2026-11-05T00:00:00Z"},
                    {"id":"b","status":"available","expires_at":null},
                    {"id":"c","status":"redeemed"},
                    {"id":"d","status":"available","expires_at":"2026-10-01T00:00:00Z"}],"available_count":3}
        """)
        let banked = try #require(CodexProvider.banked(credits, now: now))
        #expect(banked.count == 2)
        #expect(banked.nextExpiry == ISODate.parse("2026-11-05T00:00:00Z"))
        #expect(banked.grantID == "a")
    }

    @Test func `spend outcomes: answers settle, timeouts and unknown answers keep the request id`() {
        #expect(CodexProvider.consumeOutcome("already_redeemed").refilled)
        #expect(CodexProvider.consumeOutcome("no_credit").settled)
        #expect(!CodexProvider.consumeOutcome("something_new").settled)
        #expect(!RedeemOutcome.failure(URLError(.timedOut)).settled)
        #expect(!RedeemOutcome.failure(ProviderError.http(502)).settled)
        #expect(RedeemOutcome.failure(ProviderError.http(409)).settled)
        #expect(RedeemOutcome.failure(ProviderError.rateLimited(retryAfter: nil)).settled)
        #expect(RedeemOutcome.failure(ProviderError.unauthorized("Signed out")).message == "Signed out")
    }

    @Test func `banked detail names the next expiry`() {
        let expiry = ISODate.parse("2026-11-03T00:00:00Z")!
        #expect(BankedResets(kind: .fable, count: 1, nextExpiry: expiry).detail(now: now).hasPrefix("1 left · expires "))
        #expect(BankedResets(kind: nil, count: 2, nextExpiry: nil).detail(now: now) == "2 left")
        #expect(BankedResets(kind: .fable, count: 1).name == "Fable reset")
    }
}

struct HTTPTests {
    @Test func `retry after is clamped to 30 minutes`() {
        #expect(HTTP.retryAfter("120") == 120)
        #expect(HTTP.retryAfter("86400") == 1800)
        #expect(HTTP.retryAfter("-5") == 0)
    }
}

struct ServiceStatusTests {
    private let page = URL(string: "https://status.claude.com")!

    private func parse(_ json: String) throws -> ServiceStatus? {
        let summary = try decode(ServiceStatus.Summary.self, json)
        return ServiceStatus.parse(summary, watching: ["Claude Code", "Claude API"], page: page)
    }

    @Test func `all operational is no status`() throws {
        #expect(try parse("""
        {"status":{"indicator":"none","description":"All Systems Operational"},
         "components":[{"name":"Claude Code","status":"operational"},{"name":"claude.ai","status":"operational"}],
         "incidents":[]}
        """) == nil)
    }

    @Test func `an outage elsewhere on the page is ignored`() throws {
        #expect(try parse("""
        {"status":{"indicator":"major","description":"Major System Outage"},
         "components":[{"name":"Claude Code","status":"operational"},{"name":"claude.ai","status":"major_outage"}],
         "incidents":[{"name":"claude.ai is down","shortlink":"https://stspg.io/a","components":[{"name":"claude.ai","status":"major_outage"}]}]}
        """) == nil)
    }

    @Test func `a degraded watched component is named by its incident`() throws {
        let status = try #require(try parse("""
        {"status":{"indicator":"minor","description":"Minor Service Outage"},
         "components":[{"name":"Claude Code","status":"degraded_performance"},{"name":"claude.ai","status":"operational"}],
         "incidents":[{"name":"Elevated errors on Claude Code","shortlink":"https://stspg.io/b","components":[{"name":"Claude Code","status":"degraded_performance"}]}]}
        """))
        #expect(status == ServiceStatus(title: "Elevated errors on Claude Code", severity: .minor, link: URL(string: "https://stspg.io/b")!))
    }

    @Test func `an outage without an incident names the component and is major`() throws {
        let status = try #require(try parse("""
        {"status":{"indicator":"major","description":"Partial System Outage"},
         "components":[{"name":"Claude API (api.anthropic.com)","status":"partial_outage"}]}
        """))
        #expect(status == ServiceStatus(title: "Claude API (api.anthropic.com): partial outage", severity: .major, link: page))
    }

    @Test func `renamed components fall back to the page indicator`() throws {
        let status = try #require(try parse("""
        {"status":{"indicator":"critical","description":"Major System Outage"},
         "components":[{"name":"Something new","status":"major_outage"}],"incidents":[]}
        """))
        #expect(status == ServiceStatus(title: "Major System Outage", severity: .major, link: page))
    }
}

struct KeychainGateTests {
    @Test func `a locked keychain is never read in the background, and does not latch`() throws {
        let gate = KeychainGate()
        var reads = 0
        #expect(throws: ProviderError.keychainLocked) {
            try gate.read(userInitiated: false, isUnlocked: { false }) { reads += 1; return .found(Data("x".utf8)) }
        }
        #expect(reads == 0)
        #expect(!gate.isLatched)
        #expect(try gate.read(userInitiated: false, isUnlocked: { true }) { reads += 1; return .notFound } == nil)
        #expect(reads == 1)
    }

    @Test func `a failed background read stops background reads until an explicit read succeeds`() throws {
        let gate = KeychainGate()
        var reads = 0
        #expect(throws: ProviderError.keychainBlocked) {
            try gate.read(userInitiated: false, isUnlocked: { true }) { reads += 1; return .failed }
        }
        #expect(gate.isLatched)
        #expect(throws: ProviderError.keychainBlocked) {
            try gate.read(userInitiated: false, isUnlocked: { true }) { reads += 1; return .found(Data("x".utf8)) }
        }
        #expect(reads == 1)

        #expect(throws: ProviderError.keychainBlocked) {
            try gate.read(userInitiated: true, isUnlocked: { false }) { reads += 1; return .failed }
        }
        #expect(reads == 2)
        #expect(gate.isLatched)

        #expect(try gate.read(userInitiated: true, isUnlocked: { false }) { reads += 1; return .found(Data("x".utf8)) } == Data("x".utf8))
        #expect(!gate.isLatched)
        #expect(try gate.read(userInitiated: false, isUnlocked: { true }) { reads += 1; return .notFound } == nil)
        #expect(reads == 4)
    }
}
