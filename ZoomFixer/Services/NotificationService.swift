import Foundation
import UserNotifications

/// Manages completion notifications via UNUserNotificationCenter.
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sendCompletion(success: Bool, warnings: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "ZoomFixer"
        if success && !warnings {
            content.body = "✅ Zoom repaired successfully."
        } else if warnings {
            content.body = "⚠️ Zoom repair finished with warnings. Check the log."
        } else {
            content.body = "❌ Zoom repair encountered errors. Check the log."
        }
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}
