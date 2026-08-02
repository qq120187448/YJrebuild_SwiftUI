import UIKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.silv.Robo", category: "Push")

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by RoboApp after environment is ready
    var apiService: APIService?
    var deviceService: DeviceService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - Remote Notification Registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.info("APNs token registered: \(token.prefix(12))...")

        Task {
            guard let apiService else {
                logger.warning("APIService not available for APNs token registration")
                return
            }
            do {
                try await apiService.registerAPNsToken(token)
                logger.info("APNs token sent to backend")
            } catch {
                logger.error("Failed to send APNs token: \(error.localizedDescription)")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("Push registration failed: \(error.localizedDescription)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification when app is in foreground — show banner
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Post notification for badge updates
        let userInfo = notification.request.content.userInfo
        if userInfo["hit_id"] != nil {
            NotificationCenter.default.post(name: .hitResponseNotification, object: nil)
        }
        completionHandler([.banner, .sound])
    }

    /// Handle notification tap — deep link to HIT detail
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let hitId = userInfo["hit_id"] as? String {
            logger.info("Push tap → HIT \(hitId)")
            NotificationCenter.default.post(
                name: .hitCompletedNotification,
                object: nil,
                userInfo: ["hit_id": hitId]
            )
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let hitCompletedNotification = Notification.Name("hitCompletedNotification")
    static let hitResponseNotification = Notification.Name("hitResponseNotification")
    static let chatPrefillNotification = Notification.Name("chatPrefillNotification")
    static let switchToChat = Notification.Name("switchToChat")
}
