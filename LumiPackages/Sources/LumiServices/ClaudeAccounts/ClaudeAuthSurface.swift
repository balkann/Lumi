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

    /// Yüzey okumasının sonucu. `unreadable` hiçbir karara temel olamaz:
    /// keychain kilitliyken "yüzey boş" sanmak, geri yüklemede kullanıcının
    /// oturumunu silmeye kadar gider (karar 56 sertleştirmesi).
    enum Read: Sendable, Equatable {
        case available(Snapshot)
        case unreadable(detail: String)
    }

    func read() async -> Read {
        switch await readCredentials() {
        case let .found(credentials):
            return .available(Snapshot(credentialsJSON: credentials, oauthAccountJSON: readOauthAccount()))
        case .missing:
            return .available(Snapshot(credentialsJSON: nil, oauthAccountJSON: readOauthAccount()))
        case let .failed(detail):
            return .unreadable(detail: detail)
        }
    }

    /// Kapsanmış servis → düz servis → dosya sırası: CLI hangisine yazdıysa
    /// en güncel olan odur. Bir kanal OKUNAMAZSA sıradakine düşülmez — eksik
    /// bir yüzey resmi, yokluktan daha tehlikelidir.
    func readCredentials() async -> KeychainReadResult {
        switch await keychain.password(service: scopedService, account: user) {
        case let .found(value): return .found(value)
        case let .failed(detail): return .failed(detail: detail)
        case .missing: break
        }
        if scopedService != ClaudeAuthLocations.legacyKeychainService {
            switch await keychain.password(
                service: ClaudeAuthLocations.legacyKeychainService, account: user
            ) {
            case let .found(value): return .found(value)
            case let .failed(detail): return .failed(detail: detail)
            case .missing: break
            }
        }
        guard let data = FileManager.default.contents(atPath: paths.credentialsFile) else {
            return .missing
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? .missing : .found(text)
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
    ///
    /// İçerik zaten istenen hâldeyse dosyaya HİÇ dokunulmaz: `.claude.json`
    /// onlarca MB olabiliyor ve her gereksiz yeniden yazım, CLI'ın aynı anda
    /// yazdığı kaydı kaybetme penceresi açıyor.
    ///
    /// Dosya yoksa ya da ayrıştırılamıyorsa HATA fırlatılır: sessizce geçmek,
    /// "hesap değişti" denip CLI'ın eski kimliği göstermeye devam etmesi
    /// demekti.
    func writeOauthAccount(_ json: String?) throws {
        guard FileManager.default.fileExists(atPath: paths.configFile) else {
            throw LumiError.claudeAccountFailed(
                operation: "switch",
                detail: "\(paths.configFile) not found — run `claude` once to create it"
            )
        }
        guard var object = readConfigObject() else {
            throw LumiError.claudeAccountFailed(
                operation: "switch", detail: "\(paths.configFile) is not readable JSON"
            )
        }
        let current = object["oauthAccount"].flatMap(Self.encode)
        guard current != json else { return }
        if let json, let value = Self.decode(json) {
            object["oauthAccount"] = value
        } else {
            object.removeValue(forKey: "oauthAccount")
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        let url = URL(fileURLWithPath: paths.configFile)
        // İzinler atomik yazımda (yeni inode + rename) taşınmaz; dosya
        // kullanıcının oturum kimliğini taşıdığı için 0600'e sabitlenir.
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: permissions ?? 0o600], ofItemAtPath: url.path
        )
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
