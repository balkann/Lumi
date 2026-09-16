import Foundation
import LumiKit

/// Lumi'nin yönettiği kimlik bilgilerinin deposu (karar 56).
///
/// Token'lar Keychain'de (`Lumi Claude Managed Credentials` servisi, hesap adı
/// = hesap id'si), token OLMAYAN `oauthAccount` bloğu ise
/// `~/.lumi/claude-accounts/<id>/auth/oauth-account.json` içinde 0600 ile
/// durur. Disk tarafında hiçbir zaman token yazılmaz.
///
/// Ayrıca "sistem varsayılanı" anlık görüntüsünü tutar: ilk kez yönetilen bir
/// hesaba geçerken kullanıcının KENDİ `~/.claude` oturumu buraya alınır,
/// `System default`'a dönüldüğünde aynen geri yazılır.
struct ClaudeManagedAuthStore: Sendable {
    /// Sistem varsayılanının Keychain'deki hesap adı. Hesap id'leri UUID
    /// olduğu için çakışmaz.
    static let systemDefaultKey = "__lumi-system-default__"
    private static let systemDefaultDirectoryName = "system-default"
    private static let systemDefaultMarkerName = "snapshot.json"

    private let keychain: any KeychainAccessing
    private let root: URL

    init(keychain: any KeychainAccessing, root: URL) {
        self.keychain = keychain
        self.root = root
    }

    // MARK: - Hesap başına

    func readSnapshot(accountID: String) async -> ClaudeAuthSurface.Snapshot {
        ClaudeAuthSurface.Snapshot(
            credentialsJSON: await keychain.password(
                service: ClaudeAuthLocations.managedKeychainService, account: accountID
            ),
            oauthAccountJSON: readOauthAccount(accountID: accountID)
        )
    }

    func write(_ snapshot: ClaudeAuthSurface.Snapshot, accountID: String) async throws {
        if let credentials = snapshot.credentialsJSON {
            try await keychain.setPassword(
                credentials,
                service: ClaudeAuthLocations.managedKeychainService,
                account: accountID
            )
        } else {
            try await keychain.deletePassword(
                service: ClaudeAuthLocations.managedKeychainService, account: accountID
            )
        }
        try writeOauthAccount(snapshot.oauthAccountJSON, accountID: accountID)
    }

    func remove(accountID: String) async throws {
        try await keychain.deletePassword(
            service: ClaudeAuthLocations.managedKeychainService, account: accountID
        )
        let directory = ClaudeAuthLocations.managedAuthDirectory(accountID: accountID, root: root)
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Sistem varsayılanı

    /// Snapshot zaten varsa DOKUNULMAZ: ikinci bir yakalama, yönetilen bir
    /// hesabın kimlik bilgisini "sistem varsayılanı" sanıp kullanıcının gerçek
    /// oturumunu kalıcı olarak kaybettirirdi.
    func captureSystemDefaultIfNeeded(_ snapshot: ClaudeAuthSurface.Snapshot) async throws {
        guard await systemDefaultSnapshot() == nil else { return }
        if let credentials = snapshot.credentialsJSON {
            try await keychain.setPassword(
                credentials,
                service: ClaudeAuthLocations.managedKeychainService,
                account: Self.systemDefaultKey
            )
        }
        let marker: [String: Any] = [
            "hasCredentials": snapshot.credentialsJSON != nil,
            "oauthAccount": snapshot.oauthAccountJSON ?? NSNull(),
            "capturedAt": Date().timeIntervalSince1970,
        ]
        let url = systemDefaultMarkerURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted])
            .write(to: url, options: .atomic)
    }

    func systemDefaultSnapshot() async -> ClaudeAuthSurface.Snapshot? {
        guard let data = FileManager.default.contents(atPath: systemDefaultMarkerURL.path),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let hasCredentials = (marker["hasCredentials"] as? NSNumber)?.boolValue ?? false
        let credentials = hasCredentials
            ? await keychain.password(
                service: ClaudeAuthLocations.managedKeychainService,
                account: Self.systemDefaultKey
            )
            : nil
        return ClaudeAuthSurface.Snapshot(
            credentialsJSON: credentials,
            oauthAccountJSON: marker["oauthAccount"] as? String
        )
    }

    /// Sistem varsayılanına dönülüp yüzey geri yazıldıktan sonra çağrılır:
    /// snapshot tüketilmiştir, bir sonraki geçişte güncel hâl yakalanmalıdır.
    func clearSystemDefaultSnapshot() async throws {
        try await keychain.deletePassword(
            service: ClaudeAuthLocations.managedKeychainService,
            account: Self.systemDefaultKey
        )
        let url = systemDefaultMarkerURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Dosya tarafı

    private var systemDefaultMarkerURL: URL {
        root.appendingPathComponent(Self.systemDefaultDirectoryName)
            .appendingPathComponent(Self.systemDefaultMarkerName)
    }

    private func oauthAccountURL(accountID: String) -> URL {
        ClaudeAuthLocations.managedAuthDirectory(accountID: accountID, root: root)
            .appendingPathComponent(ClaudeAuthLocations.oauthAccountFileName)
    }

    private func readOauthAccount(accountID: String) -> String? {
        guard let data = FileManager.default.contents(atPath: oauthAccountURL(accountID: accountID).path)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private func writeOauthAccount(_ json: String?, accountID: String) throws {
        let url = oauthAccountURL(accountID: accountID)
        guard let json else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(json.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
