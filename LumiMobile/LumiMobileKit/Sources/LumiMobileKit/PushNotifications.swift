import Foundation

/// Sistem bildirim izni durumu (UNAuthorizationStatus'un UIKit-siz karşılığı).
public enum NotificationAuthStatus: Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// Toggle AÇ sonucu; UI'nin ne yapacağını belirler.
public enum EnableResult: Sendable, Equatable {
    case enabled        // izin var, kayıt başladı
    case needsSettings  // izin reddedilmiş → Ayarlar'a yönlendir
    case declined       // kullanıcı prompt'ta reddetti
}

/// Sistem izin API'sinin soyutlaması (prod: UNUserNotificationCenter).
public protocol NotificationAuthorizing: Sendable {
    func authorizationStatus() async -> NotificationAuthStatus
    func requestAuthorization() async -> Bool
}

/// APNs kayıt API'sinin soyutlaması (prod: UIApplication).
public protocol RemoteRegistering: Sendable {
    @MainActor func registerForRemoteNotifications()
    @MainActor func unregisterForRemoteNotifications()
}

/// AppModel'in push orkestrasyonuna eriştiği sınır (impl: PushCoordinator).
@MainActor
public protocol PushControlling: AnyObject, Sendable {
    func onPairingSucceeded() async
    func enable() async -> EnableResult
    func disable() async
    func refreshAuthStatus() async
}

/// Basit bool tercih deposu (kullanıcı ayarları; Keychain değil).
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
