import Foundation

/// Notifications that come due with time rather than with a fetch: unused weekly quota about
/// to reset, a banked reset about to expire, a limit that runs out at this pace. Each fires
/// once per limit window or expiry; what fired is kept on disk so a relaunch doesn't repeat it.
struct Reminder: Equatable {
    enum Kind: Equatable {
        /// Lead time before the reset: 24 h or 1 h.
        case unusedBeforeReset(lead: TimeInterval)
        case bankedExpiring
        case runsOut(in: TimeInterval)
    }

    var provider: ProviderID
    var kind: Kind
    var title: String
    var body: String
    /// Stable for one window or expiry, so it fires once.
    var key: String

    static let unusedLeads: [TimeInterval] = [24 * 3600, 3600]
    /// Less unused than this isn't worth a nudge.
    static let unusedMinimum = 0.25

    static func due(states: [ProviderID: ProviderState], enabled: [ProviderID], now: Date) -> [Reminder] {
        enabled.flatMap { id -> [Reminder] in
            // Only on fresh numbers: not behind an expired sign-in or a run of failed fetches.
            guard let state = states[id], state.error == nil, let snapshot = state.snapshot else { return [] }
            return snapshot.windows.flatMap { window in unused(id, window, now: now) + runsOut(id, window, now: now) }
                + (snapshot.resets ?? []).compactMap { banked(id, $0, now: now) }
        }
    }

    /// The nearest lead time already reached, so a Mac that slept through 24 h still gets 1 h.
    static func unused(_ id: ProviderID, _ window: UsageWindow, now: Date) -> [Reminder] {
        // Plan-wide limits only: an unused per-model limit (Sonnet, Spark) is normal, not a loss.
        guard window.kind == .primary, let resets = window.resetsAt, let duration = window.duration, duration >= 86400 else { return [] }
        let remaining = resets.timeIntervalSince(now)
        let left = 1 - window.used
        guard remaining > 0, left >= unusedMinimum, let lead = unusedLeads.last(where: { remaining <= $0 }) else { return [] }
        return [Reminder(
            provider: id,
            kind: .unusedBeforeReset(lead: lead),
            title: "\(id.name) \(window.label.lowercased()) limit resets \(TimeText.reset(resets, now: now, absolute: false))",
            body: "\(Int((left * 100).rounded()))% is still unused. What's left doesn't carry over.",
            key: "unused/\(id.rawValue)/\(window.id)/\(windowKey(resets))/\(Int(lead))"
        )]
    }

    /// Only once half is used: early in a window a burst says little about the rest.
    static func runsOut(_ id: ProviderID, _ window: UsageWindow, now: Date) -> [Reminder] {
        guard window.used >= 0.5, window.used < 1, let resets = window.resetsAt,
              let pace = Pace(window: window, now: now), let eta = pace.runsOutIn, eta > 0
        else { return [] }
        return [Reminder(
            provider: id,
            kind: .runsOut(in: eta),
            title: "\(id.name) \(window.label.lowercased()) limit runs out \(TimeText.reset(now.addingTimeInterval(eta), now: now, absolute: false))",
            body: "At this pace, before it resets \(TimeText.reset(resets, now: now, absolute: false)).",
            key: "pace/\(id.rawValue)/\(window.id)/\(windowKey(resets))"
        )]
    }

    /// Reset times wobble between fetches (20:59:59.6 one time, 21:00:00 the next); the
    /// nearest quarter hour stays put, so one window keeps one key.
    static func windowKey(_ resets: Date) -> Int {
        Int((resets.timeIntervalSince1970 / 900).rounded()) * 900
    }

    static func banked(_ id: ProviderID, _ resets: BankedResets, now: Date) -> Reminder? {
        guard let expiry = resets.nextExpiry, expiry > now, expiry.timeIntervalSince(now) <= 86400 else { return nil }
        return Reminder(
            provider: id,
            kind: .bankedExpiring,
            title: "\(id.name) \(resets.name.lowercased()) expires \(TimeText.reset(expiry, now: now, absolute: false))",
            body: resets.grantID == nil ? resets.effect : "\(resets.effect) Use it from the Tokei panel.",
            key: "banked/\(id.rawValue)/\(resets.name)/\(Int(expiry.timeIntervalSince1970))"
        )
    }
}

/// Checks every minute and posts what came due and hasn't fired yet.
@MainActor
final class Reminders {
    private let refresher: Refresher
    private let post: (Reminder) -> Void
    private var timer: Timer?
    static let firedKey = "reminders.fired"

    init(refresher: Refresher, post: @escaping (Reminder) -> Void) {
        self.refresher = refresher
        self.post = post
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check(now: Date = .now) {
        let defaults = UserDefaults.standard
        var fired = (defaults.dictionary(forKey: Self.firedKey) as? [String: Date] ?? [:])
            .filter { now.timeIntervalSince($0.value) < 8 * 86400 }
        for reminder in Reminder.due(states: refresher.states, enabled: refresher.enabled, now: now) where fired[reminder.key] == nil {
            fired[reminder.key] = now
            post(reminder)
        }
        defaults.set(fired, forKey: Self.firedKey)
    }
}
