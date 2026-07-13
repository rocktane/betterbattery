import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for the app's few event notifications.
enum Notifier {
    static func setup() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                bbLog.warning("Notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                bbLog.info("Notifications not authorized by user")
            }
        }
    }

    static func send(_ title: String, _ body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // One notification per event id: a new one replaces the previous.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                bbLog.warning("Failed to deliver notification \(id): \(error.localizedDescription)")
            }
        }
    }
}
