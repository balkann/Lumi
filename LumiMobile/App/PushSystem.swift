import UIKit
import UserNotifications
import LumiMobileKit
import LumiWire

/// UNUserNotificationCenter wrapper (production implementation of the Kit protocol).
struct SystemNotificationAuthorizer: NotificationAuthorizing {
    func authorizationStatus() async -> NotificationAuthStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}

/// UIApplication wrapper.
@MainActor
struct SystemRemoteRegistrar: RemoteRegistering {
    func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }
    func unregisterForRemoteNotifications() { UIApplication.shared.unregisterForRemoteNotifications() }
}

/// Bridges APNs callbacks to PushCoordinator.
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    var coordinator: PushCoordinator?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await coordinator?.handleDeviceToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DiagLog.shared.log("push", "APNs registration failed: \(error.localizedDescription)")
    }
}
