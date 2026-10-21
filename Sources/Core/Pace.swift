import Foundation

/// Linear pace (CodexBar's model): compares usage with an even spread over the window.
struct Pace: Equatable {
    /// Used minus expected, as a fraction. Positive: using faster than an even spread.
    var delta: Double
    /// Share of the window that has elapsed: where usage "should" be now.
    var expected: Double
    /// nil: lasts until reset.
    var runsOutIn: TimeInterval?

    init?(window: UsageWindow, now: Date) {
        guard let resets = window.resetsAt, let duration = window.duration, duration > 0 else { return nil }
        let remaining = resets.timeIntervalSince(now)
        guard remaining > 0, remaining <= duration else { return nil }
        let elapsed = duration - remaining
        let expected = elapsed / duration
        // The first few percent of a window say nothing useful yet.
        guard expected >= 0.03 else { return nil }
        let used = min(max(window.used, 0), 1)
        delta = used - expected
        self.expected = expected
        if used >= 1 {
            runsOutIn = 0
        } else if used == 0 {
            runsOutIn = nil
        } else {
            let eta = (1 - used) / (used / elapsed)
            runsOutIn = eta >= remaining ? nil : eta
        }
    }

    /// Within 2 points of an even spread.
    var isOnTrack: Bool { abs(delta) <= 0.02 }

    /// Usage at reset if the current rate holds, capped at 100%.
    var projected: Double { min(expected > 0 ? (delta + expected) / expected : 0, 1) }

    var runsOut: Bool { runsOutIn != nil }

    /// "~22% left at reset", or "Runs out in 2h" when the current rate won't last.
    func headline(display: UsageDisplay, now: Date) -> String {
        if let runsOutIn {
            if runsOutIn <= 60 { return "Runs out now" }
            return "Runs out \(TimeText.reset(now.addingTimeInterval(runsOutIn), now: now, absolute: false))"
        }
        let points = Int((display.value(projected) * 100).rounded())
        return display == .used ? "~\(points)% used at reset" : "~\(points)% left at reset"
    }
}
