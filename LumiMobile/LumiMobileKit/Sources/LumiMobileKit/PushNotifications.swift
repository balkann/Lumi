import Foundation

/// System notification permission status (UIKit-free equivalent of UNAuthorizationStatus).
public enum NotificationAuthStatus: Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// Result of toggling notifications ON; tells the UI what to do next.
public enum EnableResult: Sendable, Equatable {
    case enabled        // permission granted, registration started
    case needsSettings  // permission denied → redirect to Settings
    case declined       // user dismissed the permission prompt
}

/// Abstraction for the system permission API (prod: UNUserNotificationCenter).
public protocol NotificationAuthorizing: Sendable {
    func authorizationStatus() async -> NotificationAuthStatus
    func requestAuthorization() async -> Bool
}

/// Abstraction for the APNs registration API (prod: UIApplication).
public protocol RemoteRegistering: Sendable {
    @MainActor func registerForRemoteNotifications()
    @MainActor func unregisterForRemoteNotifications()
}

/// The boundary AppModel uses to access push orchestration (impl: PushCoordinator).
@MainActor
public protocol PushControlling: AnyObject, Sendable {
    func onPairingSucceeded() async
    func enable() async -> EnableResult
    func disable() async
    func refreshAuthStatus() async
}

/// Simple boolean preference store (user settings; not Keychain).
public protocol PreferenceStore: Sendable {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

public final class InMemoryPreferenceStore: PreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Bool] = [:]
    public init() {}
    public func bool(forKey key: String) -> Bool { lock.withLock { storage[key] ?? false } }
    public func set(_ value: Bool, forKey key: String) { lock.withLock { storage[key] = value } }
}

public final class UserDefaultsPreferenceStore: PreferenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}

@MainActor
public final class PushCoordinator: PushControlling {
    private let model: AppModel
    private let authorizer: any NotificationAuthorizing
    private let registrar: any RemoteRegistering

    public init(model: AppModel, authorizer: any NotificationAuthorizing, registrar: any RemoteRegistering) {
        self.model = model
        self.authorizer = authorizer
        self.registrar = registrar
    }

    /// Called when AppDelegate receives the APNs device token.
    public func handleDeviceToken(_ hex: String) async {
        await model.applyPushToken(hex)
    }

    public func refreshAuthStatus() async {
        model.setNotificationAuthStatus(await authorizer.authorizationStatus())
    }

    public func onPairingSucceeded() async {
        let status = await authorizer.authorizationStatus()
        model.setNotificationAuthStatus(status)
        guard status == .notDetermined else { return }
        _ = await requestAndRegister()
    }

    public func enable() async -> EnableResult {
        let status = await authorizer.authorizationStatus()
        model.setNotificationAuthStatus(status)
        switch status {
        case .notDetermined:
            return await requestAndRegister()
        case .denied:
            return .needsSettings
        case .authorized:
            registrar.registerForRemoteNotifications()
            await model.markNotificationsEnabled(true)
            return .enabled
        }
    }

    public func disable() async {
        await model.markNotificationsEnabled(false)
        registrar.unregisterForRemoteNotifications()
    }

    private func requestAndRegister() async -> EnableResult {
        let granted = await authorizer.requestAuthorization()
        guard granted else {
            model.setNotificationAuthStatus(.denied)
            return .declined
        }
        model.setNotificationAuthStatus(.authorized)
        registrar.registerForRemoteNotifications()
        await model.markNotificationsEnabled(true)
        return .enabled
    }
}
