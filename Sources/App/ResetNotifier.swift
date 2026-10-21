import Foundation
import UserNotifications

/// Posts "Claude session reset" when a refresh sees a limit reset. Detection lives in
/// `Refresher.resets(old:new:)`; this only talks to the notification center.
enum ResetNotifier {
    static func requestPermissionIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Prefs.notifyResetsKey) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ id: ProviderID, _ window: UsageWindow) {
        guard UserDefaults.standard.bool(forKey: Prefs.notifyResetsKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(id.name) \(window.label.lowercased()) limit reset"
        content.body = "Fresh quota is available."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "reset-\(id.rawValue)-\(window.id)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
