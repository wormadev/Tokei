import Foundation
import Synchronization
@testable import Tokei
import Testing

private struct StubProvider: UsageProvider {
    let id: ProviderID
    var installed = true
    var activityFolder: URL { URL.temporaryDirectory }
    func isInstalled() -> Bool { installed }
    func fetch(userInitiated: Bool) async throws -> Snapshot { throw ProviderError.http(500) }
}

private final class CountingProvider: UsageProvider, Sendable {
    let id = ProviderID.claude
    let fetches = Mutex(0)
    var activityFolder: URL { URL.temporaryDirectory }
    func isInstalled() -> Bool { true }
    func fetch(userInitiated: Bool) async throws -> Snapshot {
        fetches.withLock { $0 += 1 }
        try await Task.sleep(for: .milliseconds(100))
        throw ProviderError.http(500)
    }
}

private func snapshot(used: Double, at date: Date) -> Snapshot {
    Snapshot(windows: [UsageWindow(id: "session", label: "Session", kind: .primary, used: used)], account: Account(), fetchedAt: date)
}

/// The test host is the real app, so UserDefaults.standard holds the developer's own settings and
/// registerDefaults never ran. The argument domain outranks both and is never written to disk.
@MainActor
private func useTestDefaults() {
    let defaults = UserDefaults.standard
    var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    for id in ProviderID.allCases { arguments[Prefs.enabledKey(id)] = true }
    arguments[Prefs.showStatusKey] = false
    arguments[Prefs.refreshIntervalKey] = Prefs.agentAwareInterval
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
}

private func tempStore() -> StateStore {
    StateStore(url: URL.temporaryDirectory.appending(path: "tokei-test-\(UUID().uuidString).json"))
}

@MainActor
struct RefresherTests {
    init() {
        useTestDefaults()
    }

    private func makeRefresher(store: StateStore = tempStore()) -> Refresher {
        Refresher(providers: [StubProvider(id: .claude)], store: store)
    }

    @Test func `error keeps the last good snapshot`() {
        let refresher = makeRefresher()
        let now = Date(timeIntervalSince1970: 1_000_000)
        refresher.apply(.success(snapshot(used: 0.3, at: now)), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.http(502)), to: .claude, now: now.addingTimeInterval(300))

        let state = refresher.states[.claude]
        #expect(state?.snapshot?.windows.first?.used == 0.3)
        #expect(state?.error == "Server returned HTTP 502")
        #expect(state?.failures == 1)
    }

    @Test func `not configured drops the snapshot so a signed-out account stops showing`() {
        let refresher = makeRefresher()
        let now = Date(timeIntervalSince1970: 1_000_000)
        refresher.apply(.success(snapshot(used: 0.3, at: now)), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.notConfigured("Sign in")), to: .claude, now: now)
        #expect(refresher.states[.claude]?.snapshot == nil)
        #expect(refresher.states[.claude]?.error == "Sign in")

        refresher.clear(.claude)
        #expect(refresher.states[.claude] == nil)
    }

    @Test func `an expired sign-in notifies once and needs the user, a server error does neither`() {
        let refresher = makeRefresher()
        var notified: [String] = []
        refresher.onSignInExpired = { _, hint, _ in notified.append(hint) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        refresher.apply(.success(snapshot(used: 0.3, at: now)), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.http(502)), to: .claude, now: now)
        #expect(refresher.states[.claude]?.needsSignIn == false)

        refresher.apply(.failure(ProviderError.unauthorized("Run `claude`")), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.unauthorized("Run `claude`")), to: .claude, now: now)
        #expect(refresher.states[.claude]?.needsSignIn == true)
        #expect(notified == ["Run `claude`"])

        refresher.apply(.success(snapshot(used: 0.3, at: now)), to: .claude, now: now)
        #expect(refresher.states[.claude]?.needsSignIn == false)
        refresher.apply(.failure(ProviderError.unauthorized("Run `claude`")), to: .claude, now: now)
        #expect(notified.count == 2)
    }

    @Test func `a token past its saved expiry needs the user but does not notify, a server 401 notifies once`() {
        let refresher = makeRefresher()
        var calls: [(hint: String, rejected: Bool)] = []
        refresher.onSignInExpired = { calls.append(($1, $2)) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        refresher.apply(.success(snapshot(used: 0.3, at: now)), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.signInExpired("Run `claude` once")), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.signInExpired("Run `claude` once")), to: .claude, now: now)
        #expect(refresher.states[.claude]?.needsSignIn == true)
        #expect(refresher.states[.claude]?.snapshot != nil)
        #expect(calls.map(\.rejected) == [false])

        refresher.apply(.success(snapshot(used: 0.3, at: now)), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.unauthorized("Run `claude`")), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.unauthorized("Run `claude`")), to: .claude, now: now)
        #expect(calls.filter(\.rejected).map(\.hint) == ["Run `claude`"])
    }

    @Test func `an unreadable keychain keeps the numbers without a badge or notification`() {
        let refresher = makeRefresher()
        var notified = 0
        refresher.onSignInExpired = { _, _, _ in notified += 1 }
        let now = Date(timeIntervalSince1970: 1_000_000)
        refresher.apply(.success(snapshot(used: 0.3, at: now)), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.keychainLocked), to: .claude, now: now)
        let state = refresher.states[.claude]
        #expect(state?.snapshot?.windows.first?.used == 0.3)
        #expect(state?.needsSignIn == false)
        #expect(state?.keychainUnavailable == true)
        #expect(state?.error == "Keychain is locked. Refresh to try again.")
        #expect(notified == 0)
    }

    @Test func `a rate limit after a rejected sign-in keeps the sign-in alert`() {
        let refresher = makeRefresher()
        let now = Date(timeIntervalSince1970: 1_000_000)
        refresher.apply(.failure(ProviderError.unauthorized("Run `claude`")), to: .claude, now: now)
        refresher.apply(.failure(ProviderError.rateLimited(retryAfter: 3600)), to: .claude, now: now)
        let state = refresher.states[.claude]
        #expect(state?.needsSignIn == true)
        #expect(state?.error == "Run `claude`")
        #expect(state?.retryAt == now.addingTimeInterval(3600))
    }

    @Test func `due right when the sign-in expires, once`() {
        let refresher = makeRefresher()
        let now = Date(timeIntervalSince1970: 1_000_000)
        var fresh = snapshot(used: 0.1, at: now)
        fresh.signInExpiresAt = now.addingTimeInterval(60)
        refresher.apply(.success(fresh), to: .claude, now: now)
        #expect(!refresher.isDue(.claude, now: now.addingTimeInterval(59), interval: 900))
        #expect(refresher.isDue(.claude, now: now.addingTimeInterval(61), interval: 900))
        #expect(!refresher.isDue(.claude, now: now.addingTimeInterval(61), interval: nil))

        refresher.apply(.failure(ProviderError.unauthorized("Run `claude`")), to: .claude, now: now.addingTimeInterval(61))
        #expect(!refresher.isDue(.claude, now: now.addingTimeInterval(120), interval: 900))
    }

    @Test func `a missing sign-in needs the user without an expiry notification`() {
        let refresher = makeRefresher()
        var notified = 0
        refresher.onSignInExpired = { _, _, _ in notified += 1 }
        refresher.apply(.failure(ProviderError.notConfigured("Sign in")), to: .claude, now: .now)
        #expect(refresher.states[.claude]?.needsSignIn == true)
        #expect(notified == 0)
    }

    @Test func `a second refresh joins the one under way, refresh after current starts anew`() async {
        let provider = CountingProvider()
        let store = StateStore(url: URL.temporaryDirectory.appending(path: "tokei-test-\(UUID().uuidString).json"))
        let refresher = Refresher(providers: [provider], store: store)
        async let first: Void = refresher.refresh(.claude)
        async let second: Void = refresher.refresh(.claude)
        _ = await (first, second)
        #expect(provider.fetches.withLock { $0 } == 1)

        let background = Task { await refresher.refresh(.claude) }
        await Task.yield()
        await refresher.refreshAfterCurrent(.claude)
        await background.value
        #expect(provider.fetches.withLock { $0 } == 3)
        #expect(refresher.refreshing.isEmpty)
    }

    @Test func `providers that are not installed are left out of the panel`() {
        let store = StateStore(url: URL.temporaryDirectory.appending(path: "tokei-test-\(UUID().uuidString).json"))
        let refresher = Refresher(providers: [StubProvider(id: .claude), StubProvider(id: .codex, installed: false)], store: store)
        #expect(refresher.installed == [.claude])
        #expect(refresher.enabled == [.claude])
    }

    @Test func `opening the panel waits out a 429 but retries other failures`() async throws {
        let provider = CountingProvider()
        let refresher = Refresher(providers: [provider], store: tempStore())
        let then = Date.now.addingTimeInterval(-200)
        refresher.apply(.failure(ProviderError.rateLimited(retryAfter: 3600)), to: .claude, now: then)
        refresher.refreshOnOpen()
        try await Task.sleep(for: .milliseconds(300))
        #expect(provider.fetches.withLock { $0 } == 0)

        refresher.apply(.failure(URLError(.notConnectedToInternet)), to: .claude, now: then)
        #expect(try #require(refresher.states[.claude]?.retryAt) > .now)
        refresher.refreshOnOpen()
        for _ in 0 ..< 30 where provider.fetches.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(provider.fetches.withLock { $0 } == 1)
    }

    @Test func `reset alerts only for snapshots fetched this launch, recently, on the same account`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = { (used: Double, resets: TimeInterval) in
            UsageWindow(id: "session", label: "Session", kind: .primary, used: used, resetsAt: now.addingTimeInterval(resets), duration: 5 * 3600)
        }
        let snap = { (used: Double, resets: TimeInterval, at: TimeInterval, user: String) in
            Snapshot(windows: [window(used, resets)], account: Account(user: user), fetchedAt: now.addingTimeInterval(at))
        }
        var alerts = 0

        let refresher = makeRefresher()
        refresher.onReset = { _, _ in alerts += 1 }
        refresher.apply(.success(snap(0.6, 60, -3600, "a")), to: .claude, now: now.addingTimeInterval(-3600))
        refresher.apply(.success(snap(0, 5 * 3600 + 60, 0, "a")), to: .claude, now: now)
        #expect(alerts == 1)

        refresher.apply(.success(snap(0.6, 5 * 3600 + 60, 0, "a")), to: .claude, now: now)
        refresher.apply(.success(snap(0, 10 * 3600 + 60, 6 * 3600, "b")), to: .claude, now: now.addingTimeInterval(6 * 3600))
        #expect(alerts == 1)

        refresher.apply(.success(snap(0.6, 10 * 3600 + 60, 6 * 3600, "b")), to: .claude, now: now.addingTimeInterval(6 * 3600))
        refresher.apply(.success(snap(0, 20 * 3600, 12 * 3600, "b")), to: .claude, now: now.addingTimeInterval(12 * 3600))
        #expect(alerts == 1)

        let store = tempStore()
        store.save(.init(states: [.claude: ProviderState(snapshot: snap(0.6, -60, -3600, "a"))], history: History()))
        let relaunched = makeRefresher(store: store)
        relaunched.onReset = { _, _ in alerts += 1 }
        relaunched.apply(.success(snap(0, 5 * 3600 - 60, 0, "a")), to: .claude, now: now)
        #expect(alerts == 1)
    }

    @Test func `opening the panel refreshes unless just fetched or rate limited`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Refresher.isStaleOnOpen(nil, now: now))
        var state = ProviderState(lastAttempt: now.addingTimeInterval(-5))
        #expect(!Refresher.isStaleOnOpen(state, now: now))
        state.lastAttempt = now.addingTimeInterval(-30)
        #expect(Refresher.isStaleOnOpen(state, now: now))
        // Failure backoff doesn't hold back a refresh the user asked for by opening the panel.
        state.retryAt = now.addingTimeInterval(600)
        #expect(Refresher.isStaleOnOpen(state, now: now))
        state.rateLimited = true
        #expect(!Refresher.isStaleOnOpen(state, now: now))
    }

    @Test func `a 429 is remembered as rate limited until a success`() {
        let refresher = makeRefresher()
        let now = Date(timeIntervalSince1970: 1_000_000)
        refresher.apply(.failure(ProviderError.rateLimited(retryAfter: 60)), to: .claude, now: now)
        #expect(refresher.states[.claude]?.rateLimited == true)
        refresher.apply(.failure(ProviderError.http(500)), to: .claude, now: now)
        #expect(refresher.states[.claude]?.rateLimited == nil)
        refresher.apply(.failure(ProviderError.rateLimited(retryAfter: 60)), to: .claude, now: now)
        refresher.apply(.success(snapshot(used: 0.1, at: now)), to: .claude, now: now)
        #expect(refresher.states[.claude]?.rateLimited == nil)
    }

    @Test func `due after interval, and after retryAt when failing`() {
        let refresher = makeRefresher()
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(refresher.isDue(.claude, now: now, interval: 300))
        refresher.apply(.success(snapshot(used: 0.1, at: now)), to: .claude, now: now)
        #expect(!refresher.isDue(.claude, now: now.addingTimeInterval(299), interval: 300))
        #expect(refresher.isDue(.claude, now: now.addingTimeInterval(300), interval: 300))
        #expect(!refresher.isDue(.claude, now: now.addingTimeInterval(86400), interval: nil))

        refresher.apply(.failure(ProviderError.rateLimited(retryAfter: 900)), to: .claude, now: now)
        #expect(!refresher.isDue(.claude, now: now.addingTimeInterval(899), interval: 300))
        #expect(refresher.isDue(.claude, now: now.addingTimeInterval(900), interval: 300))
    }

    @Test func `backoff doubles, caps at 30 minutes, 429 waits at least 5 minutes`() {
        let error = ProviderError.http(500)
        #expect(Refresher.backoff(error: error, failures: 1, interval: 60) == 60)
        #expect(Refresher.backoff(error: error, failures: 3, interval: 60) == 240)
        #expect(Refresher.backoff(error: error, failures: 20, interval: 300) == 1800)
        #expect(Refresher.backoff(error: ProviderError.rateLimited(retryAfter: nil), failures: 1, interval: 60) == 300)
        #expect(Refresher.backoff(error: ProviderError.rateLimited(retryAfter: 1200), failures: 1, interval: 60) == 1200)
    }
}

struct TransientErrorTests {
    @Test func `rate limits and server errors are transient, sign-in problems are not`() {
        #expect(Refresher.isTransient(ProviderError.rateLimited(retryAfter: nil)))
        #expect(Refresher.isTransient(ProviderError.http(503)))
        #expect(Refresher.isTransient(URLError(.notConnectedToInternet)))
        #expect(!Refresher.isTransient(ProviderError.unauthorized("x")))
        #expect(!Refresher.isTransient(ProviderError.notConfigured("x")))
    }
}

struct AgentActivityTests {
    @MainActor
    @Test func `a write in a watched folder records activity`() async throws {
        let folder = URL.temporaryDirectory.appending(path: "tokei-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let activity = AgentActivity(latency: 0.1)
        activity.watch([.claude: folder])
        try await Task.sleep(for: .milliseconds(300))
        try Data("x".utf8).write(to: folder.appending(path: "session.jsonl"))
        for _ in 0 ..< 50 where activity.lastActivity[.claude] == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(activity.lastActivity[.claude] != nil)
        #expect(activity.lastActivity[.codex] == nil)
    }

    @Test func `five minutes while an agent wrote recently, fifteen when idle`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AgentActivity.interval(lastActivity: now.addingTimeInterval(-60), now: now) == 300)
        #expect(AgentActivity.interval(lastActivity: now.addingTimeInterval(-6 * 60), now: now) == 900)
        #expect(AgentActivity.interval(lastActivity: nil, now: now) == 900)
    }
}

struct HistoryTests {
    @Test func `samples at most every 15 minutes and drops points older than 7 days`() {
        var history = History()
        let start = Date(timeIntervalSince1970: 1_000_000)
        history.record(.codex, snapshot: snapshot(used: 0.1, at: start))
        history.record(.codex, snapshot: snapshot(used: 0.2, at: start.addingTimeInterval(300)))
        #expect(history.points(.codex, "session").map(\.used) == [0.2])

        history.record(.codex, snapshot: snapshot(used: 0.3, at: start.addingTimeInterval(16 * 60)))
        #expect(history.points(.codex, "session").count == 2)

        history.record(.codex, snapshot: snapshot(used: 0.5, at: start.addingTimeInterval(8 * 86400)))
        #expect(history.points(.codex, "session").map(\.used) == [0.5])
    }
}

struct FormattingTests {
    @Test func `relative reset and ago labels`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(TimeText.reset(now.addingTimeInterval(2 * 3600 + 13 * 60), now: now, absolute: false) == "in 2h 13m")
        #expect(TimeText.reset(now.addingTimeInterval(3 * 86400 + 4 * 3600), now: now, absolute: false) == "in 3d 4h")
        #expect(TimeText.reset(now.addingTimeInterval(10), now: now, absolute: false) == "in 1m")
        #expect(TimeText.ago(now.addingTimeInterval(-30), now: now) == "now")
        #expect(TimeText.ago(now.addingTimeInterval(-180), now: now) == "3m ago")
    }

    @Test func `retry after accepts seconds and HTTP dates`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(HTTP.retryAfter("120", now: now) == 120)
        #expect(HTTP.retryAfter("Mon, 12 Jan 1970 13:46:40 GMT", now: now) == 0)
        #expect(HTTP.retryAfter(nil) == nil)
    }
}

struct MenuBarIconTests {
    private func state(_ windows: [UsageWindow]) -> ProviderState {
        ProviderState(snapshot: Snapshot(windows: windows, account: Account(), fetchedAt: .now))
    }

    private func config(_ limits: [String], provider: ProviderID? = nil, numbers: MenuBarConfig.Numbers = .all) -> MenuBarConfig {
        MenuBarConfig(provider: provider, limits: limits, style: .rings, numbers: numbers, logo: false)
    }

    private func used(_ icon: MenuBarIcon) -> [Double?] { icon.meters.map(\.used) }

    private let states: [ProviderID: ProviderState] = [
        .claude: ProviderState(snapshot: Snapshot(windows: [
            UsageWindow(id: "session", label: "Session", kind: .primary, used: 0.13),
            UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: 0.43),
            UsageWindow(id: "weekly-fable", label: "Fable weekly", kind: .secondary, used: 0.9),
        ], account: Account(), fetchedAt: .now)),
        .codex: ProviderState(snapshot: Snapshot(windows: [UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: 0.7)], account: Account(), fetchedAt: .now)),
    ]

    @Test func `meters follow the chosen limits of the first provider in order`() {
        let icon = MenuBarIcon.make(states: states, enabled: [.claude, .codex], config: config(["weekly", "weekly-fable"]), display: .used)
        #expect(icon.provider == .claude)
        #expect(used(icon) == [0.43, 0.9])
        #expect(icon.lines == ["43%", "90%"])
        let codexFirst = MenuBarIcon.make(states: states, enabled: [.codex, .claude], config: config(["session", "weekly"]), display: .used)
        // Codex has no session here: left out, not drawn empty.
        #expect(used(codexFirst) == [0.7])
        #expect(codexFirst.lines == ["70%"])
        #expect(used(MenuBarIcon.make(states: states, enabled: [], config: config(["session"]), display: .used)) == [nil])
    }

    @Test func `a chosen provider wins unless it is hidden`() {
        let picked = MenuBarIcon.make(states: states, enabled: [.claude, .codex], config: config(["weekly"], provider: .codex), display: .used)
        #expect(picked.provider == .codex)
        let hidden = MenuBarIcon.make(states: states, enabled: [.claude], config: config(["weekly"], provider: .codex), display: .used)
        #expect(hidden.provider == .claude)
        // A limit Codex never has isn't drawn as an empty ring forever: its main limit stands in.
        #expect(used(MenuBarIcon.make(states: states, enabled: [.codex], config: config(["weekly-fable"]), display: .used)) == [0.7])
    }

    @Test func `numbers show none, the first, or every limit`() {
        let make = { (numbers: MenuBarConfig.Numbers, display: UsageDisplay) in
            MenuBarIcon.make(states: states, enabled: [.claude], config: config(["session", "weekly"], numbers: numbers), display: display).lines
        }
        #expect(make(.all, .used) == ["13%", "43%"])
        #expect(make(.first, .remaining) == ["87%"])
        #expect(make(.hidden, .used).isEmpty)
    }

    @Test func `limits past their reset are unknown, and an expired sign-in dims and badges`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var claude = state([
            UsageWindow(id: "session", label: "Session", kind: .primary, used: 0.8, resetsAt: now.addingTimeInterval(-60)),
            UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: 0.4, resetsAt: now.addingTimeInterval(3600)),
        ])
        let make = { MenuBarIcon.make(states: [.claude: claude, .codex: self.state([])], enabled: [.codex, .claude], config: self.config(["session", "weekly"], provider: .claude), display: .used, now: now) }
        #expect(used(make()) == [nil, 0.4])

        claude.error = "Sign-in expired"
        #expect(make().stale)
        #expect(make().badge)
        claude.transient = true
        #expect(!make().stale)
    }

    @Test func `highest usage follows the fullest limit`() {
        let highest = MenuBarConfig(highest: true, limits: ["weekly"], style: .rings, numbers: .first, logo: false)
        let icon = MenuBarIcon.make(states: states, enabled: [.claude, .codex], config: highest, display: .used)
        #expect(icon.provider == .claude)
        #expect(icon.logo)
        let codexOnly = MenuBarIcon.make(states: states, enabled: [.codex], config: highest, display: .used)
        #expect(codexOnly.provider == .codex)
    }

    @Test func `codex windows without lengths fall back to slot order`() {
        let codex: [ProviderID: ProviderState] = [.codex: state([
            UsageWindow(id: "primary", label: "", kind: .primary, used: 0.2),
            UsageWindow(id: "secondary", label: "", kind: .primary, used: 0.5),
        ])]
        #expect(used(MenuBarIcon.make(states: codex, enabled: [.codex], config: config(["session", "weekly"]), display: .used)) == [0.2, 0.5])
    }
}

struct PrefsTests {
    @Test func `usage display flips used and remaining`() {
        #expect(UsageDisplay.used.text(0.43) == "43%")
        #expect(UsageDisplay.remaining.text(0.43) == "57%")
        #expect(UsageDisplay.remaining.value(1.2) == 0)
    }

    @MainActor @Test func `a shortcut survives storage and junk stores nothing`() {
        let shortcut = HotKey.Shortcut(keyCode: 17, modifiers: 6144, display: "⌃⌥T")
        #expect(HotKey.Shortcut(stored: shortcut.stored) == shortcut)
        #expect(HotKey.Shortcut(stored: "") == nil)
        #expect(HotKey.Shortcut(stored: "x,1,A") == nil)
    }

    @Test func `countdowns round up and drop zero parts`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(TimeText.reset(now.addingTimeInterval(30), now: now, absolute: false) == "in 1m")
        #expect(TimeText.reset(now.addingTimeInterval(2 * 86400), now: now, absolute: false) == "in 2d")
        #expect(TimeText.reset(now.addingTimeInterval(3 * 3600), now: now, absolute: false) == "in 3h")
        #expect(TimeText.reset(now.addingTimeInterval(3 * 3600 + 61), now: now, absolute: false) == "in 3h 2m")
    }

    @Test func `low power and heat stretch background refresh`() {
        #expect(Refresher.saving(300, lowPower: false, thermal: .nominal) == 300)
        #expect(Refresher.saving(300, lowPower: true, thermal: .nominal) == 1800)
        #expect(Refresher.saving(300, lowPower: false, thermal: .serious) == 1800)
        #expect(Refresher.saving(3600, lowPower: true, thermal: .nominal) == 3600)
    }

    @Test func `plans without a session limit show weekly with the spark inside`() {
        let weeklyOnly: [ProviderID: ProviderState] = [
            .claude: ProviderState(snapshot: Snapshot(windows: [UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: 0.46)], account: Account(), fetchedAt: .now)),
        ]
        let config = { (numbers: MenuBarConfig.Numbers) in
            MenuBarConfig(limits: ["session", "weekly"], style: .rings, numbers: numbers, logo: false)
        }
        let icon = MenuBarIcon.make(states: weeklyOnly, enabled: [.claude], config: config(.first), display: .used)
        #expect(icon.lines == ["46%"])
        #expect(icon.spark)
        #expect(MenuBarIcon.make(states: weeklyOnly, enabled: [.claude], config: config(.hidden), display: .used).lines.isEmpty)
        let sessionReset: [ProviderID: ProviderState] = [
            .claude: ProviderState(snapshot: Snapshot(windows: [
                UsageWindow(id: "session", label: "Session", kind: .primary, used: 0.5, resetsAt: .now.addingTimeInterval(-60)),
                UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: 0.46),
            ], account: Account(), fetchedAt: .now)),
        ]
        let reset = MenuBarIcon.make(states: sessionReset, enabled: [.claude], config: config(.first), display: .used)
        #expect(reset.lines.isEmpty)
        #expect(!reset.spark)
    }

    @Test func `provider order keeps saved order and appends missing providers`() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Prefs.providerOrderKey)
        defer { defaults.set(saved, forKey: Prefs.providerOrderKey) }
        defaults.set("codex,cursor,bogus", forKey: Prefs.providerOrderKey)
        #expect(Prefs.providerOrder == [.codex, .claude])
        Prefs.providerOrder = [.claude, .codex]
        #expect(Prefs.providerOrder == [.claude, .codex])
    }
}

struct ResetDetectionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snap(_ used: Double, resets: TimeInterval?, kind: UsageWindow.Kind = .primary) -> Snapshot {
        Snapshot(windows: [UsageWindow(id: "session", label: "Session", kind: kind, used: used, resetsAt: resets.map { now.addingTimeInterval($0) })], account: Account(), fetchedAt: now)
    }

    @Test func `usage drop with the reset time moving forward is a reset`() {
        #expect(Refresher.resets(old: snap(0.6, resets: 0), new: snap(0.0, resets: 5 * 3600)).map(\.id) == ["session"])
    }

    @Test func `crossing 80 and 95 percent notifies once per threshold, again after a reset`() {
        let crossed = { (old: Snapshot, new: Snapshot) in Refresher.lowCrossings(old: old, new: new, now: now).map(\.1) }
        #expect(crossed(snap(0.5, resets: 3600), snap(0.82, resets: 3600)) == [0.8])
        #expect(crossed(snap(0.82, resets: 3600), snap(0.9, resets: 3600)).isEmpty)
        #expect(crossed(snap(0.5, resets: 3600), snap(0.97, resets: 3600)) == [0.95])
        #expect(crossed(snap(0.97, resets: 0), snap(0.85, resets: 5 * 3600)) == [0.8])
        #expect(crossed(snap(0.5, resets: 3600, kind: .secondary), snap(0.81, resets: 3600, kind: .secondary)) == [0.8])
    }

    @Test func `jitter, unused limits and per-model limits are not resets`() {
        #expect(Refresher.resets(old: snap(0.6, resets: 0), new: snap(0.5, resets: 120)).isEmpty)
        #expect(Refresher.resets(old: snap(0.0, resets: 0), new: snap(0.0, resets: 5 * 3600)).isEmpty)
        #expect(Refresher.resets(old: snap(0.6, resets: 0, kind: .secondary), new: snap(0, resets: 5 * 3600, kind: .secondary)).isEmpty)
        #expect(Refresher.resets(old: snap(0.6, resets: nil), new: snap(0, resets: 5 * 3600)).isEmpty)
    }
}

struct ReminderTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func weekly(used: Double, resetsIn: TimeInterval) -> UsageWindow {
        UsageWindow(id: "weekly", label: "Weekly", kind: .primary, used: used, resetsAt: now.addingTimeInterval(resetsIn), duration: 7 * 86400)
    }

    @Test func `unused weekly quota warns a day and an hour before reset, keyed per stage`() {
        #expect(Reminder.unused(.codex, weekly(used: 0.4, resetsIn: 30 * 3600), now: now).isEmpty)
        let day = Reminder.unused(.codex, weekly(used: 0.4, resetsIn: 20 * 3600), now: now)
        #expect(day.map(\.kind) == [.unusedBeforeReset(lead: 86400)])
        #expect(day.first?.body.hasPrefix("60% is still unused") == true)
        let hour = Reminder.unused(.codex, weekly(used: 0.4, resetsIn: 1800), now: now)
        #expect(hour.map(\.kind) == [.unusedBeforeReset(lead: 3600)])
        #expect(day.first?.key != hour.first?.key)
        #expect(Reminder.unused(.codex, weekly(used: 0.9, resetsIn: 1800), now: now).isEmpty)
        let session = UsageWindow(id: "session", label: "Session", kind: .primary, used: 0.1, resetsAt: now.addingTimeInterval(1800), duration: 18000)
        #expect(Reminder.unused(.codex, session, now: now).isEmpty)
        var sonnet = weekly(used: 0, resetsIn: 1800)
        sonnet.kind = .secondary
        #expect(Reminder.unused(.claude, sonnet, now: now).isEmpty)
    }

    @Test func `pace warns once half is used and it runs out before the reset`() {
        // Half the week gone, 80% used: runs out well before the reset.
        let fast = weekly(used: 0.8, resetsIn: 3.5 * 86400)
        #expect(Reminder.runsOut(.claude, fast, now: now).count == 1)
        // The reset time wobbles by a second between fetches; still the same reminder.
        var wobble = fast
        wobble.resetsAt = fast.resetsAt?.addingTimeInterval(0.4)
        #expect(Reminder.runsOut(.claude, wobble, now: now).first?.key == Reminder.runsOut(.claude, fast, now: now).first?.key)
        #expect(Reminder.runsOut(.claude, weekly(used: 0.3, resetsIn: 3.5 * 86400), now: now).isEmpty)
        #expect(Reminder.runsOut(.claude, weekly(used: 0.5, resetsIn: 3.5 * 86400), now: now).isEmpty)
    }

    @Test func `a banked reset expiring within a day reminds, and nothing comes from an expired sign-in`() {
        let soon = BankedResets(kind: .fable, count: 1, nextExpiry: now.addingTimeInterval(3600), grantID: "f")
        #expect(Reminder.banked(.claude, soon, now: now)?.title == "Claude fable reset expires in 1h")
        #expect(Reminder.banked(.claude, BankedResets(kind: .full, count: 1, nextExpiry: now.addingTimeInterval(3 * 86400)), now: now) == nil)

        var snapshot = Snapshot(windows: [], account: Account(), fetchedAt: now)
        snapshot.resets = [soon]
        var state = ProviderState(snapshot: snapshot)
        #expect(Reminder.due(states: [.claude: state], enabled: [.claude], now: now).count == 1)
        state.error = "Sign-in expired"
        #expect(Reminder.due(states: [.claude: state], enabled: [.claude], now: now).isEmpty)
        state.transient = true
        #expect(Reminder.due(states: [.claude: state], enabled: [.claude], now: now).isEmpty)
    }
}
