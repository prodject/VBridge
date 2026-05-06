import Foundation
import UIKit
import UserNotifications

enum AppNotificationIdentifier {
    static let connectionIssue = "com.prodject.vbridge.connection.issue"

    static func captcha(_ requestID: String) -> String {
        "com.prodject.vbridge.captcha.\(requestID)"
    }
}

@MainActor
final class UserNotificationDispatcher {
    static let shared = UserNotificationDispatcher()

    private let center = UNUserNotificationCenter.current()
    private var didRequestAuthorization = false

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                SharedLogger.warning("Notification authorization request failed: \(error.localizedDescription)")
                return
            }

            SharedLogger.info("Notification authorization \(granted ? "granted" : "denied")")
        }
    }

    func notifyCaptchaIfNeeded(request: CaptchaRequest) {
        notifyIfAppInactive(
            identifier: AppNotificationIdentifier.captcha(request.id),
            title: "Captcha required",
            message: request.message.isEmpty
                ? "Open VBridge to finish the captcha challenge."
                : request.message
        )
    }

    func clearCaptchaNotification(requestID: String?) {
        guard let requestID else { return }
        clear(identifier: AppNotificationIdentifier.captcha(requestID))
    }

    func notifyConnectionIssue(title: String, message: String) {
        notifyIfAppInactive(
            identifier: AppNotificationIdentifier.connectionIssue,
            title: title,
            message: message
        )
    }

    func clearConnectionIssueNotification() {
        clear(identifier: AppNotificationIdentifier.connectionIssue)
    }

    private func notifyIfAppInactive(identifier: String, title: String, message: String) {
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(request) { error in
            if let error {
                SharedLogger.warning("Failed to schedule notification \(identifier): \(error.localizedDescription)")
            }
        }
    }

    private func clear(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
