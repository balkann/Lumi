import UIKit
import UserNotifications
import LumiMobileKit

/// UNUserNotificationCenter sarmalayıcısı (Kit protokolünün prod implementasyonu).
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

/// UIApplication sarmalayıcısı.
@MainActor
struct SystemRemoteRegistrar: RemoteRegistering {
    func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }
    func unregisterForRemoteNotifications() { UIApplication.shared.unregisterForRemoteNotifications() }
}

/// APNs callback'lerini PushCoordinator'a köprüler.
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    var coordinator: PushCoordinator?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await coordinator?.handleDeviceToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DiagLog.shared.log("push", "APNs kayıt başarısız: \(error.localizedDescription)")
    }
}
