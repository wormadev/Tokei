import Foundation
import UserNotifications

/// Posts resets, limits running low and expired sign-ins. Detection lives in `Refresher`;
/// this only talks to the notification center.
enum Notifier {
    static func requestPermissionIfEnabled() {
        let defaults = UserDefaults.standard
        let keys = [Prefs.notifyResetsKey, Prefs.notifySignInKey, Prefs.notifyLowKey, Prefs.notifyUnusedKey, Prefs.notifyBankedKey]
        guard keys.contains(where: defaults.bool(forKey:)) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// "Claude weekly limit: 20% left" / "Resets in 2d 4h".
    static func postRunningLow(_ id: ProviderID, _ window: UsageWindow, threshold: Double, now: Date = .now) {
        guard UserDefaults.standard.bool(forKey: Prefs.notifyLowKey) else { return }
        let left = Int(((1 - window.used) * 100).rounded())
        let title = left <= 0 ? "\(id.name) \(window.label.lowercased()) limit used up" : "\(id.name) \(window.label.lowercased()) limit: \(left)% left"
        let body = window.resetsAt.map { "Resets \(TimeText.reset($0, now: now, absolute: false))." } ?? ""
        post(id: "low-\(id.rawValue)-\(window.id)-\(threshold)", title: title, body: body)
    }

    static func postReset(_ id: ProviderID, _ window: UsageWindow) {
        guard UserDefaults.standard.bool(forKey: Prefs.notifyResetsKey) else { return }
        post(id: "reset-\(id.rawValue)-\(window.id)", title: "\(id.name) \(window.label.lowercased()) limit reset", body: "Your \(window.label.lowercased()) limit is full again.")
    }

    static func postReminder(_ reminder: Reminder) {
        let key = switch reminder.kind {
        case .unusedBeforeReset: Prefs.notifyUnusedKey
        case .bankedExpiring: Prefs.notifyBankedKey
        case .runsOut: Prefs.notifyLowKey
        }
        guard UserDefaults.standard.bool(forKey: key) else { return }
        post(id: reminder.key, title: reminder.title, body: reminder.body)
    }

    static func postSignInExpired(_ id: ProviderID) {
        guard UserDefaults.standard.bool(forKey: Prefs.notifySignInKey) else { return }
        let cli = Connector.statusCommands[id]?.cli ?? id.name.lowercased()
        post(id: "sign-in-\(id.rawValue)", title: "\(id.name) sign-in expired", body: "Usage won't update until you run \(cli).")
    }

    private static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(id)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
