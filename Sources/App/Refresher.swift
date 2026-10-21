import AppKit
import Foundation
import Observation

struct ProviderState: Codable, Equatable {
    /// Last good data. Kept through errors so the panel never blanks out.
    var snapshot: Snapshot?
    var error: String?
    var failures = 0
    var lastAttempt: Date?
    /// Earliest next background attempt after a failure or 429.
    var retryAt: Date?
}

/// Owns all fetching. One 30 s tick decides who is due, so there is a single timer, it can
/// pause on sleep/lock, and settings changes take effect on the next tick without rescheduling.
@MainActor
@Observable
final class Refresher {
    private(set) var states: [ProviderID: ProviderState] = [:]
    private(set) var refreshing: Set<ProviderID> = []
    private(set) var history = History()

    @ObservationIgnored private let providers: [ProviderID: any UsageProvider]
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(providers: [any UsageProvider], store: StateStore = StateStore()) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.store = store
        if let saved = store.load() {
            states = saved.states
            history = saved.history
        }
    }

    var enabled: [ProviderID] {
        ProviderID.allCases.filter { Prefs.isEnabled($0) && providers[$0] != nil }
    }

    func start() {
        observeSystem()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(10))
            }
        }
    }

    /// Manual refresh ignores backoff: the user asked, and errors show immediately.
    func refreshAll() {
        for id in enabled { Task { await refresh(id) } }
    }

    /// Panel opened: anything older than a minute is worth a quiet refresh.
    func refreshStale(maxAge: TimeInterval = 60) {
        let now = Date.now
        for id in enabled where (states[id]?.lastAttempt).map({ now.timeIntervalSince($0) > maxAge }) ?? true {
            if let retryAt = states[id]?.retryAt, retryAt > now { continue }
            Task { await refresh(id) }
        }
    }

    func refreshDue(now: Date = .now) async {
        guard !paused else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in enabled where isDue(id, now: now) {
                group.addTask { await self.refresh(id) }
            }
        }
    }

    func isDue(_ id: ProviderID, now: Date) -> Bool {
        guard let state = states[id], let last = state.lastAttempt else { return true }
        if let retryAt = state.retryAt { return now >= retryAt }
        return now.timeIntervalSince(last) >= Prefs.refreshInterval
    }

    func refresh(_ id: ProviderID) async {
        guard let provider = providers[id], !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        let result: Result<Snapshot, Error>
        do {
            result = try .success(await provider.fetch())
        } catch {
            result = .failure(error)
        }
        apply(result, to: id, now: .now)
    }

    func apply(_ result: Result<Snapshot, Error>, to id: ProviderID, now: Date) {
        var state = states[id] ?? ProviderState()
        state.lastAttempt = now
        switch result {
        case let .success(snapshot):
            state.snapshot = snapshot
            state.error = nil
            state.failures = 0
            state.retryAt = nil
            history.record(id, snapshot: snapshot)
        case let .failure(error):
            state.failures += 1
            state.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state.retryAt = now.addingTimeInterval(Self.backoff(error: error, failures: state.failures))
        }
        states[id] = state
        store.save(.init(states: states, history: history))
    }

    /// Doubles the interval per consecutive failure, capped at 30 min. 429 waits at least 5 min.
    static func backoff(error: Error, failures: Int, interval: TimeInterval = Prefs.refreshInterval) -> TimeInterval {
        let exponential = min(interval * pow(2, Double(max(0, failures - 1))), 30 * 60)
        if case let .rateLimited(retryAfter) = error as? ProviderError {
            return max(retryAfter ?? 0, 5 * 60, exponential)
        }
        return exponential
    }

    // MARK: - Sleep / lock

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pause: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.paused = true } }
        let resume: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.paused = false
                // Give Wi-Fi a moment to come back before hitting the network.
                try? await Task.sleep(for: .seconds(5))
                await self?.refreshDue()
            }
        }
        observers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: pause),
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: resume),
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: pause),
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: resume),
        ]
    }
}

/// Usage samples for the history sparkline: at most one point per window per 15 min, 7 days kept.
struct History: Codable, Equatable {
    struct Point: Codable, Equatable {
        var date: Date
        var used: Double
    }

    /// Key: "provider/window".
    var series: [String: [Point]] = [:]

    static func key(_ id: ProviderID, _ window: String) -> String { "\(id.rawValue)/\(window)" }

    func points(_ id: ProviderID, _ window: String) -> [Point] {
        series[Self.key(id, window)] ?? []
    }

    mutating func record(_ id: ProviderID, snapshot: Snapshot) {
        let cutoff = snapshot.fetchedAt.addingTimeInterval(-7 * 86400)
        for window in snapshot.windows {
            let key = Self.key(id, window.id)
            var points = (series[key] ?? []).filter { $0.date > cutoff }
            if let last = points.last, snapshot.fetchedAt.timeIntervalSince(last.date) < 15 * 60 {
                points[points.count - 1].used = window.used
            } else {
                points.append(Point(date: snapshot.fetchedAt, used: window.used))
            }
            series[key] = points
        }
    }
}

struct StateStore {
    struct Saved: Codable {
        var states: [ProviderID: ProviderState]
        var history: History
    }

    var url: URL = URL.applicationSupportDirectory.appending(path: "Quota/state.json")

    func load() -> Saved? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    func save(_ saved: Saved) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: url, options: .atomic)
    }
}
