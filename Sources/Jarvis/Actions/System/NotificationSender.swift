import Foundation
import UserNotifications

/// Protocol for delivering notifications, decoupling policy/dispatching from platform UserNotifications.
@MainActor
protocol NotificationDelivering: Sendable {
    func requestAuthorization() async -> Bool
    func sendNotification(title: String, subtitle: String?, body: String)
}

/// A no-op notification delivery backend for tests or environments without bundle support.
@MainActor
final class NullNotificationDelivery: NotificationDelivering {
    var sentNotifications: [(title: String, subtitle: String?, body: String)] = []

    func requestAuthorization() async -> Bool { false }

    func sendNotification(title: String, subtitle: String?, body: String) {
        sentNotifications.append((title, subtitle, body))
        JarvisLogger.actions.debug("NullNotificationDelivery: recorded notification '\(title)'")
    }
}

/// Standard macOS UNUserNotificationCenter delivery backend.
@MainActor
final class UserNotificationCenterDelivery: NotificationDelivering {
    private var lazyCenter: UNUserNotificationCenter?
    private var isAuthorized = false

    private func getCenter() -> UNUserNotificationCenter? {
        if let existing = lazyCenter { return existing }
        // Verify we have a valid app bundle and are not running under XCTest
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else {
            return nil
        }
        let center = UNUserNotificationCenter.current()
        self.lazyCenter = center
        return center
    }

    func requestAuthorization() async -> Bool {
        guard let center = getCenter() else { return false }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            self.isAuthorized = granted
            return granted
        } catch {
            JarvisLogger.actions.error("Notification permission error: \(error.localizedDescription)")
            return false
        }
    }

    func sendNotification(title: String, subtitle: String?, body: String) {
        guard let center = getCenter() else {
            JarvisLogger.actions.debug("Notification center unavailable in current environment. Dropped '\(title)'")
            return
        }
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

/// Dispatches macOS system notifications for JARVIS events and alerts.
@MainActor
final class NotificationSender {
    static let shared = NotificationSender()

    var backend: any NotificationDelivering

    init(backend: any NotificationDelivering = UserNotificationCenterDelivery()) {
        self.backend = backend
    }

    // MARK: - Permissions

    func requestAuthorization() async -> Bool {
        await backend.requestAuthorization()
    }

    // MARK: - Public API

    /// Send a local notification.
    func sendNotification(title: String, subtitle: String? = nil, body: String) {
        backend.sendNotification(title: title, subtitle: subtitle, body: body)
    }
}
