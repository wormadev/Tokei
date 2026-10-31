import Foundation
import UserNotifications

/// Posts "Claude session reset" and "Claude sign-in expired". Detection lives in `Refresher`;
/// this only talks to the notification center.
enum Notifier {
    static func requestPermissionIfEnabled() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.notifyResetsKey) || defaults.bool(forKey: Prefs.notifySignInKey) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postReset(_ id: ProviderID, _ window: UsageWindow) {
        guard UserDefaults.standard.bool(forKey: Prefs.notifyResetsKey) else { return }
        post(id: "reset-\(id.rawValue)-\(window.id)", title: "\(id.name) \(window.label.lowercased()) limit reset", body: "Fresh quota is available.")
    }

    /// The hint is Markdown for the panel ("Run `claude` …"); notifications show it as plain text.
    static func postSignInExpired(_ id: ProviderID, hint: String) {
        guard UserDefaults.standard.bool(forKey: Prefs.notifySignInKey) else { return }
        post(id: "sign-in-\(id.rawValue)", title: "\(id.name) sign-in expired", body: hint.replacing("`", with: ""))
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
