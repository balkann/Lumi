import CryptoKit
import Foundation
import LumiKit

/// Claude Code'un kimlik bilgisini aradığı yerler + Lumi'nin yönettiği
/// kopyaların yerleri (karar 56). Saf hesaplama — I/O yok, test edilebilir.
public enum ClaudeAuthLocations {
    /// Claude Code'un klasik (sürüm < 2.1) keychain servisi.
    public static let legacyKeychainService = "Claude Code-credentials"
    /// Lumi'nin yönetilen kopyalarını sakladığı servis; hesap adı = hesap id'si.
    public static let managedKeychainService = "Lumi Claude Managed Credentials"
    public static let credentialsFileName = ".credentials.json"
    public static let oauthAccountFileName = "oauth-account.json"

    /// Claude Code 2.1+ keychain servisini config dizinine göre kapsar:
    /// `Claude Code-credentials-<sha256(configDir)[0..8]>` (Orca'nın
    /// doğruladığı şema). Varsayılan `~/.claude` için de suffix hesaplanır;
    /// yazarken İKİ servis birden güncellenir, böylece eski ve yeni CLI
    /// sürümleri aynı hesabı görür.
    public static func scopedKeychainService(configDir: String) -> String {
        let digest = SHA256.hash(data: Data(configDir.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(legacyKeychainService)-\(suffix)"
    }

    /// Keychain kayıtlarının hesap adı — Claude Code `$USER` kullanır.
    public static func keychainUser(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        environment["USER"] ?? environment["USERNAME"] ?? "user"
    }

    /// Aktif yüzeyin dosya yolları. `CLAUDE_CONFIG_DIR` miras alınmışsa ona,
    /// yoksa `~/.claude`'a bakılır; `.claude.json` (oauthAccount'ın yaşadığı
    /// dosya) config dizininde yoksa ev dizinindekine düşülür — Claude Code'un
    /// kendi çözümleme sırası.
    public static func runtime(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ClaudeRuntimeAuthPaths {
        let inherited = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configDir = (inherited?.isEmpty == false)
            ? inherited!
            : (homeDirectory as NSString).appendingPathComponent(".claude")
        let colocated = (configDir as NSString).appendingPathComponent(".claude.json")
        let configFile = (inherited?.isEmpty == false) || fileExists(colocated)
            ? colocated
            : (homeDirectory as NSString).appendingPathComponent(".claude.json")
        return ClaudeRuntimeAuthPaths(
            configDir: configDir,
            credentialsFile: (configDir as NSString).appendingPathComponent(credentialsFileName),
            configFile: configFile
        )
    }

    /// Bir hesabın yönetilen auth dizini: `~/.lumi/claude-accounts/<id>/auth`.
    public static func managedAuthDirectory(accountID: String, root: URL) -> URL {
        root.appendingPathComponent(accountID).appendingPathComponent("auth")
    }
}

public struct ClaudeRuntimeAuthPaths: Sendable, Equatable {
    public let configDir: String
    public let credentialsFile: String
    public let configFile: String

    public init(configDir: String, credentialsFile: String, configFile: String) {
        self.configDir = configDir
        self.credentialsFile = credentialsFile
        self.configFile = configFile
    }
}
