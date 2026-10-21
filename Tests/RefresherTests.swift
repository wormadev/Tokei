import Foundation
@testable import Tokei
import Testing

private struct StubProvider: UsageProvider {
    let id: ProviderID
    var installed = true
    var activityFolder: URL { URL.temporaryDirectory }
    func isInstalled() -> Bool { installed }
    func fetch() async throws -> Snapshot { throw ProviderError.http(500) }
}

private func snapshot(used: Double, at date: Date) -> Snapshot {
    Snapshot(windows: [UsageWindow(id: "session", label: "Session", kind: .primary, used: used)], account: Account(), fetchedAt: date)
}

@MainActor
struct RefresherTests {
    private func makeRefresher() -> Refresher {
        let store = StateStore(url: URL.temporaryDirectory.appending(path: "quota-test-\(UUID().uuidString).json"))
        return Refresher(providers: [StubProvider(id: .claude)], store: store)
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

        refresher.apply(.failure(ProviderError.needsConnect("Connect")), to: .claude, now: now)
        #expect(refresher.states[.claude]?.needsConnect == true)
        refresher.apply(.success(snapshot(used: 0.1, at: now)), to: .claude, now: now)
        #expect(refresher.states[.claude]?.needsConnect == nil)

        refresher.clear(.claude)
        #expect(refresher.states[.claude] == nil)
    }

    @Test func `providers that are not installed are left out of the panel`() {
        let store = StateStore(url: URL.temporaryDirectory.appending(path: "tokei-test-\(UUID().uuidString).json"))
        let refresher = Refresher(providers: [StubProvider(id: .claude), StubProvider(id: .codex, installed: false)], store: store)
        #expect(refresher.installed == [.claude])
        #expect(!refresher.enabled.contains(.codex))
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

    @Test func `two minutes while an agent wrote recently, fifteen when idle`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AgentActivity.interval(lastActivity: now.addingTimeInterval(-60), now: now) == 120)
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

struct MenuRingsTests {
    private func state(_ windows: [UsageWindow]) -> ProviderState {
        ProviderState(snapshot: Snapshot(windows: windows, account: Account(), fetchedAt: .now))
    }

    @Test func `rings follow the first provider in order`() {
        let states: [ProviderID: ProviderState] = [
            .claude: state([
                UsageWindow(id: "session", label: "", kind: .primary, used: 0.13),
                UsageWindow(id: "weekly", label: "", kind: .primary, used: 0.43),
                UsageWindow(id: "weekly-example", label: "", kind: .secondary, used: 0.9),
            ]),
            .codex: state([UsageWindow(id: "weekly", label: "", kind: .primary, used: 0.7)]),
        ]
        #expect(StatusBarController.ringValues(states, enabled: [.claude, .codex]) == .init(session: 0.13, weekly: 0.43))
        #expect(StatusBarController.ringValues(states, enabled: [.codex, .claude]) == .init(session: nil, weekly: 0.7))
        #expect(StatusBarController.ringValues(states, enabled: []) == .init(session: nil, weekly: nil))
    }

    @Test func `codex windows without lengths fall back to slot order`() {
        let states: [ProviderID: ProviderState] = [.codex: state([
            UsageWindow(id: "primary", label: "", kind: .primary, used: 0.2),
            UsageWindow(id: "secondary", label: "", kind: .primary, used: 0.5),
        ])]
        #expect(StatusBarController.ringValues(states, enabled: [.codex]) == .init(session: 0.2, weekly: 0.5))
    }
}

struct PrefsTests {
    @Test func `usage display flips used and remaining`() {
        #expect(UsageDisplay.used.text(0.43) == "43%")
        #expect(UsageDisplay.remaining.text(0.43) == "57%")
        #expect(UsageDisplay.remaining.value(1.2) == 0)
    }

    @Test func `menu bar lines stack session over weekly and label only when both`() {
        let rings = StatusBarController.Rings(session: 0.13, weekly: 0.43)
        #expect(StatusBarController.menuLines(rings, weekly: true, session: true, display: .used) == ["5h 13%", "W 43%"])
        #expect(StatusBarController.menuLines(rings, weekly: false, session: true, display: .remaining) == ["87%"])
        #expect(StatusBarController.menuLines(rings, weekly: false, session: false, display: .used).isEmpty)
        #expect(StatusBarController.menuLines(.init(session: nil, weekly: 0.5), weekly: true, session: true, display: .used) == ["W 50%"])
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

    @Test func `jitter, unused limits and per-model limits are not resets`() {
        #expect(Refresher.resets(old: snap(0.6, resets: 0), new: snap(0.5, resets: 120)).isEmpty)
        #expect(Refresher.resets(old: snap(0.0, resets: 0), new: snap(0.0, resets: 5 * 3600)).isEmpty)
        #expect(Refresher.resets(old: snap(0.6, resets: 0, kind: .secondary), new: snap(0, resets: 5 * 3600, kind: .secondary)).isEmpty)
        #expect(Refresher.resets(old: snap(0.6, resets: nil), new: snap(0, resets: 5 * 3600)).isEmpty)
    }
}
