import SwiftUI

enum Design {
    /// The panel is the only Liquid Glass surface; everything inside it is a fill.
    static let panelRadius: CGFloat = 20
    /// Concentric with the panel: its radius minus the 12 pt panel padding.
    static let radius: CGFloat = 8
    static let innerRadius: CGFloat = 4
    static let panelWidth: CGFloat = 340

    /// Neutral until it matters: orange from 80%, red from 95%.
    static func color(for used: Double) -> Color {
        switch used {
        case 0.95...: .red
        case 0.8...: .orange
        default: .primary.opacity(0.75)
        }
    }
}

extension View {
    /// A content module on the panel. A fill, not glass: no glass on glass.
    func card() -> some View {
        padding(12).background(.fill.quaternary, in: .rect(cornerRadius: Design.radius))
    }
}

enum TimeText {
    /// "now", "3m ago", "2h ago". Coarse on purpose so the label doesn't tick every second.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }

    /// "in 2h 13m", "in 3d 4h", or absolute "Tue 14:00".
    static func reset(_ date: Date, now: Date, absolute: Bool) -> String {
        if absolute {
            let sameDay = Calendar.current.isDate(date, inSameDayAs: now)
            return sameDay
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        let minutes = Int(max(0, date.timeIntervalSince(now)) / 60)
        let (days, hours, mins) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(mins)m" }
        return "in \(max(mins, 1))m"
    }
}
