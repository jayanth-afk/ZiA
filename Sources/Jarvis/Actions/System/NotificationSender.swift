import Foundation
import UserNotifications

/// Dispatches macOS system notifications for JARVIS events and alerts.
@MainActor
final class NotificationSender {
    static let shared = NotificationSender()

    private let center = UNUserNotificationCenter.current()
    private var isAuthorized = false

    private init() {}

    // MARK: - Permissions

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            self.isAuthorized = granted
            return granted
        } catch {
            JarvisLogger.actions.error("Notification permission error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Public API

    /// Send a local notification.
    func sendNotification(title: String, subtitle: String? = nil, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        center.add(request) { error in
            if let error = error {
                JarvisLogger.actions.error("Failed to post notification: \(error.localizedDescription)")
            } else {
                JarvisLogger.actions.info("Sent notification: '\(title)'")
            }
        }
    }
}
