import Foundation
import Security

public struct PairingInfo: Sendable, Equatable {
    public let relayUrl: String
    public let token: String

    public init(relayUrl: String, token: String) {
        self.relayUrl = relayUrl
        self.token = token
    }
}

public enum Pairing {
    /// `lumi-remote://pair?url=<pct>&token=<pct>` → PairingInfo.
    /// URLComponents query değerlerini kendisi percent-decode eder.
    public static func parse(_ string: String) -> PairingInfo? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "lumi-remote",
              components.host == "pair",
              let items = components.queryItems,
              let url = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              token.count >= 16,
              url.hasPrefix("wss://") || url.hasPrefix("ws://")
        else { return nil }
        return PairingInfo(relayUrl: url, token: token)
    }
}

/// Eşleştirme bilgisinin güvenli saklanması. Üretimde Keychain; testte in-memory.
public protocol SecureStore: Sendable {
    func read() -> PairingInfo?
    func write(_ info: PairingInfo)
    func clear()
}

public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PairingInfo?

    public init() {}

    public func read() -> PairingInfo? { lock.withLock { stored } }
    public func write(_ info: PairingInfo) { lock.withLock { stored = info } }
    public func clear() { lock.withLock { stored = nil } }
}

/// kSecClassGenericPassword altında tek kayıt (tasarım §7: token Keychain'de).
/// İnce I/O katmanı — birim testi yok, Task 10 uçtan uca doğrulamasıyla kapsanır.
public final class KeychainStore: SecureStore {
    private let service = "com.lumi.LumiMobile.pairing"
    private let account = "default"

    public init() {}

    public func read() -> PairingInfo? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let url = dict["relayUrl"], let token = dict["token"]
        else { return nil }
        return PairingInfo(relayUrl: url, token: token)
    }

    public func write(_ info: PairingInfo) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["relayUrl": info.relayUrl, "token": info.token]
        ) else { return }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
