import Foundation
import UserNotifications

/// Sends a local macOS notification when a repair run completes.
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sendCompletion(success: Bool, hadWarnings: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "ZoomFixer"
        if success && !hadWarnings {
            content.body = "Zoom repaired successfully ✅"
            content.sound = .default
        } else if success {
            content.body = "Zoom repair finished with warnings ⚠️"
            content.sound = .default
        } else {
            content.body = "Zoom repair encountered errors ❌"
            content.sound = .defaultCritical
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
