import Foundation
import LumiKit

/// `KeychainAccessing` test ikamesi (karar 56): bellekte servis+hesap → parola
/// sözlüğü. Gerçek keychain'e ASLA dokunulmaz — testler kullanıcının Claude
/// oturumunu bozamaz.
public actor FakeKeychain: KeychainAccessing {
    public private(set) var writes: [String] = []
    public private(set) var deletes: [String] = []
    private var storage: [String: String] = [:]
    private var failingServices: Set<String> = []
    /// Okumanın HATA verdiği servisler (kilitli keychain / reddedilen erişim).
    private var unreadableServices: Set<String> = []

    public init(storage: [String: String] = [:]) {
        self.storage = storage
    }

    /// `service|account` biçiminde anahtar — testlerin doğrudan kurabilmesi için.
    public static func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }

    public func seed(_ value: String?, service: String, account: String) {
        storage[Self.key(service: service, account: account)] = value
    }

    public func stored(service: String, account: String) -> String? {
        storage[Self.key(service: service, account: account)]
    }

    /// Bu servise yapılan yazma/silme çağrıları hata fırlatır (rollback yolları).
    public func failWrites(service: String) {
        failingServices.insert(service)
    }

    public func allowWrites(service: String) {
        failingServices.remove(service)
    }

    public func allowReads(service: String) {
        unreadableServices.remove(service)
    }

    /// Bu servisten okuma `failed` döner — "kayıt yok" ile karışmasın diye
    /// ayrı bir kapı (karar 56 sertleştirmesi).
    public func failReads(service: String) {
        unreadableServices.insert(service)
    }

    public func password(service: String, account: String) async -> KeychainReadResult {
        if unreadableServices.contains(service) {
            return .failed(detail: "fake keychain is locked")
        }
        guard let value = storage[Self.key(service: service, account: account)] else {
            return .missing
        }
        return .found(value)
    }

    public func setPassword(_ value: String, service: String, account: String) async throws {
        let key = Self.key(service: service, account: account)
        writes.append(key)
        guard !failingServices.contains(service) else {
            throw LumiError.claudeAccountFailed(operation: "keychain write", detail: "fake failure")
        }
        storage[key] = value
    }

    public func deletePassword(service: String, account: String) async throws {
        let key = Self.key(service: service, account: account)
        deletes.append(key)
        guard !failingServices.contains(service) else {
            throw LumiError.claudeAccountFailed(operation: "keychain delete", detail: "fake failure")
        }
        storage[key] = nil
    }
}
