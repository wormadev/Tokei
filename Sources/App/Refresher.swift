import AppKit
import Foundation
import Observation

struct ProviderState: Codable, Equatable {
    /// Last good data. Kept through errors so the panel never blanks out.
    var snapshot: Snapshot?
    var error: String?
    /// Rate limit, network or server hiccup: the last numbers still stand. Optional for old state.
    var transient: Bool?
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
    /// Providers whose CLI or sign-in exists on this Mac. Others are hidden from the panel.
    private(set) var installed: Set<ProviderID> = []
    private(set) var history = History()
    /// Open incidents from the providers' status pages. Not persisted: an old outage isn't news.
    private(set) var statuses: [ProviderID: ServiceStatus] = [:]

    @ObservationIgnored var onReset: ((ProviderID, UsageWindow) -> Void)?
    @ObservationIgnored private let providers: [ProviderID: any UsageProvider]
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Separate flags: waking usually lands on the lock screen, which must stay paused.
    @ObservationIgnored private let activity = AgentActivity()
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(providers: [any UsageProvider], store: StateStore = StateStore()) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.store = store
        if let saved = store.load() {
            states = saved.states
            history = saved.history
        }
        detectInstalled()
    }

    var enabled: [ProviderID] {
        Prefs.providerOrder.filter { Prefs.isEnabled($0) && installed.contains($0) }
    }

    private func watchAgents() {
        guard Prefs.refreshSetting == Prefs.agentAwareInterval else { return }
        activity.watch(Dictionary(uniqueKeysWithValues: providers.values.map { ($0.id, $0.activityFolder) }))
    }

    /// Re-checked every tick so a CLI installed while Tokei runs shows up within a minute.
    func detectInstalled() {
        let found = Set(providers.values.filter { $0.isInstalled() }.map(\.id))
        if found != installed { installed = found }
    }

    func start() {
        observeSystem()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.detectInstalled()
                self?.watchAgents()
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
    func refreshStale(maxAge: TimeInterval = 120) {
        detectInstalled()
        let now = Date.now
        for id in enabled where (states[id]?.lastAttempt).map({ now.timeIntervalSince($0) > maxAge }) ?? true {
            if let retryAt = states[id]?.retryAt, retryAt > now { continue }
            Task { await refresh(id) }
        }
    }

    func refreshDue(now: Date = .now) async {
        guard !asleep, !locked else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in enabled where isDue(id, now: now, interval: interval(for: id, now: now)) {
                group.addTask { await self.refresh(id) }
            }
        }
    }

    /// nil: no background refresh (Never).
    func interval(for id: ProviderID, now: Date) -> TimeInterval? {
        switch Prefs.refreshSetting {
        case Prefs.agentAwareInterval: AgentActivity.interval(lastActivity: activity.lastActivity[id], now: now)
        case Prefs.neverInterval: nil
        default: Prefs.refreshInterval
        }
    }

    func isDue(_ id: ProviderID, now: Date, interval: TimeInterval?) -> Bool {
        guard let state = states[id], let last = state.lastAttempt else { return true }
        // "Only when opened": no background refresh after the first fetch.
        guard let interval else { return false }
        if let retryAt = state.retryAt { return now >= retryAt }
        return now.timeIntervalSince(last) >= interval
    }

    func refresh(_ id: ProviderID) async {
        guard let provider = providers[id], !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        async let status: Void = refreshStatus(id)
        let result: Result<Snapshot, Error>
        do {
            result = try .success(await provider.fetch())
        } catch {
            result = .failure(error)
        }
        apply(result, to: id, now: .now)
        await status
    }

    /// An unreachable status page clears the badge rather than leaving an old incident up.
    private func refreshStatus(_ id: ProviderID) async {
        guard UserDefaults.standard.bool(forKey: Prefs.showStatusKey) else {
            statuses[id] = nil
            return
        }
        do {
            statuses[id] = try await ServiceStatus.fetch(id)
        } catch {
            statuses[id] = nil
        }
    }

    func apply(_ result: Result<Snapshot, Error>, to id: ProviderID, now: Date) {
        var state = states[id] ?? ProviderState()
        state.lastAttempt = now
        switch result {
        case let .success(snapshot):
            if let old = state.snapshot {
                for window in Self.resets(old: old, new: snapshot) { onReset?(id, window) }
            }
            state.snapshot = snapshot
            state.error = nil
            state.transient = nil
            state.failures = 0
            state.retryAt = nil
            history.record(id, snapshot: snapshot)
        case let .failure(error):
            // Signed out or credentials gone: old numbers would belong to a different (or no) account.
            switch error as? ProviderError {
            case .notConfigured?: state.snapshot = nil
            default: break
            }
            state.transient = Self.isTransient(error) ? true : nil
            state.failures += 1
            state.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state.retryAt = now.addingTimeInterval(Self.backoff(error: error, failures: state.failures))
        }
        states[id] = state
        store.save(.init(states: states, history: history))
    }

    /// Limits that reset between two snapshots: usage dropped and the reset time moved forward
    /// (by more than reset-time jitter). Only real limits that had been used count.
    nonisolated static func resets(old: Snapshot, new: Snapshot) -> [UsageWindow] {
        new.windows.filter { window in
            guard window.kind == .primary,
                  let before = old.windows.first(where: { $0.id == window.id }),
                  before.used > 0.01, window.used < before.used,
                  let oldReset = before.resetsAt, let newReset = window.resetsAt
            else { return false }
            return newReset.timeIntervalSince(oldReset) > 10 * 60
        }
    }

    func clear(_ id: ProviderID) {
        states[id] = nil
        store.save(.init(states: states, history: history))
    }

    nonisolated static func isTransient(_ error: Error) -> Bool {
        switch error as? ProviderError {
        case .rateLimited?, .http?, .badResponse?: true
        case .notConfigured?, .unauthorized?: false
        case nil: error is URLError
        }
    }

    /// Doubles the interval per consecutive failure, capped at 30 min. 429 waits at least 5 min.
    static func backoff(error: Error, failures: Int, interval: TimeInterval = Prefs.refreshInterval ?? 300) -> TimeInterval {
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
        let set: @Sendable (PauseReason, Bool) -> @Sendable (Notification) -> Void = { [weak self] reason, on in
            { _ in Task { @MainActor in await self?.setPaused(reason, on) } }
        }
        observers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: set(.sleep, true)),
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: set(.sleep, false)),
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: set(.lock, true)),
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: set(.lock, false)),
        ]
    }

    enum PauseReason: Sendable { case sleep, lock }

    private func setPaused(_ reason: PauseReason, _ on: Bool) async {
        switch reason {
        case .sleep: asleep = on
        case .lock: locked = on
        }
        guard !on else { return }
        // Give Wi-Fi a moment to come back before hitting the network.
        try? await Task.sleep(for: .seconds(5))
        await refreshDue()
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

    var url: URL = URL.applicationSupportDirectory.appending(path: "Tokei/state.json")

    func load() -> Saved? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    func save(_ saved: Saved) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: url, options: .atomic)
    }
}
