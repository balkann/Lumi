import Foundation
import LumiKit

/// Claude Code'un okuduğu "aktif yüzey": Keychain kaydı + `.credentials.json`
/// + `.claude.json` içindeki `oauthAccount` (karar 56).
///
/// Hesap değiştirmek = seçilen hesabın kimlik bilgisini BU yüzeye yazmak.
/// Üç kanal birden yazılır çünkü CLI sürümüne ve kuruluma göre hangisinin
/// okunacağı değişir (2.1+ kapsanmış keychain servisi, eskiler düz servis,
/// keychain'e yazamayan kurulumlar dosya).
struct ClaudeAuthSurface: Sendable {
    /// Yüzeyin o anki hâli — sistem varsayılanını geri yükleyebilmek için
    /// bire bir saklanır.
    struct Snapshot: Sendable, Equatable {
        var credentialsJSON: String?
        var oauthAccountJSON: String?
    }

    private let keychain: any KeychainAccessing
    private let paths: ClaudeRuntimeAuthPaths
    private let user: String

    init(
        keychain: any KeychainAccessing,
        paths: ClaudeRuntimeAuthPaths = ClaudeAuthLocations.runtime(),
        user: String = ClaudeAuthLocations.keychainUser()
    ) {
        self.keychain = keychain
        self.paths = paths
        self.user = user
    }

    private var scopedService: String {
        ClaudeAuthLocations.scopedKeychainService(configDir: paths.configDir)
    }

    // MARK: - Okuma

    func read() async -> Snapshot {
        Snapshot(credentialsJSON: await readCredentials(), oauthAccountJSON: readOauthAccount())
    }

    /// Kapsanmış servis → düz servis → dosya sırası: CLI hangisine yazdıysa
    /// en güncel olan odur.
    func readCredentials() async -> String? {
        if let scoped = await keychain.password(service: scopedService, account: user) {
            return scoped
        }
        if let legacy = await keychain.password(
            service: ClaudeAuthLocations.legacyKeychainService, account: user
        ) {
            return legacy
        }
        guard let data = FileManager.default.contents(atPath: paths.credentialsFile) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `.claude.json` ▸ `oauthAccount` — ham JSON metni olarak (hangi hesabın
    /// oturumda olduğunu CLI buradan gösterir).
    func readOauthAccount() -> String? {
        guard let object = readConfigObject(), let value = object["oauthAccount"] else { return nil }
        return Self.encode(value)
    }

    // MARK: - Yazma

    func write(_ snapshot: Snapshot) async throws {
        if let credentials = snapshot.credentialsJSON {
            try await writeCredentials(credentials)
        } else {
            try await clearCredentials()
        }
        try writeOauthAccount(snapshot.oauthAccountJSON)
    }

    func writeCredentials(_ credentialsJSON: String) async throws {
        try writeCredentialsFile(credentialsJSON)
        // Eski sürümler düz servisi, 2.1+ kapsanmışı okur — ikisi de yazılır.
        try await keychain.setPassword(credentialsJSON, service: scopedService, account: user)
        if scopedService != ClaudeAuthLocations.legacyKeychainService {
            try await keychain.setPassword(
                credentialsJSON, service: ClaudeAuthLocations.legacyKeychainService, account: user
            )
        }
    }

    func clearCredentials() async throws {
        if FileManager.default.fileExists(atPath: paths.credentialsFile) {
            try FileManager.default.removeItem(atPath: paths.credentialsFile)
        }
        try await keychain.deletePassword(service: scopedService, account: user)
        if scopedService != ClaudeAuthLocations.legacyKeychainService {
            try await keychain.deletePassword(
                service: ClaudeAuthLocations.legacyKeychainService, account: user
            )
        }
    }

    /// `oauthAccount` anahtarını yerinde günceller; `nil` anahtarı siler.
    /// Dosyanın geri kalanı (proje geçmişi vb.) korunur — yalnız anahtar
    /// sırası JSON yeniden yazımında normalize olur.
    func writeOauthAccount(_ json: String?) throws {
        guard var object = readConfigObject() else { return }
        if let json, let value = Self.decode(json) {
            object["oauthAccount"] = value
        } else {
            object.removeValue(forKey: "oauthAccount")
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: paths.configFile), options: .atomic)
    }

    // MARK: - Yardımcılar

    private func writeCredentialsFile(_ credentialsJSON: String) throws {
        let url = URL(fileURLWithPath: paths.credentialsFile)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(credentialsJSON.utf8).write(to: url, options: .atomic)
        // Token dosyası yalnız kullanıcıya açık kalmalı.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readConfigObject() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: paths.configFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// JSON değerini metne çevirir. Tek başına bir değer (dict/array) olduğu
    /// için `fragmentsAllowed` gerekir.
    static func encode(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }
}
