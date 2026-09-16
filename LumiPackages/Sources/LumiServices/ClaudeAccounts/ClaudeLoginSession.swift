import Foundation
import LumiKit

/// Bir Claude hesabını YALITILMIŞ biçimde oturum açtırır (karar 56).
///
/// Akış (Orca paritesi): geçici bir `CLAUDE_CONFIG_DIR` yaratılır, orada
/// `claude auth login --claudeai` koşar (tarayıcı açılır), ardından
/// `claude auth status --json` ile kimlik okunur ve credentials yakalanır.
/// Geçici dizine ait Keychain kaydı silinip kullanıcının ÖNCEKİ aktif kaydı
/// geri yazılır — login akışı kullanıcının o anki oturumunu bozmaz.
struct ClaudeLoginSession: Sendable {
    /// Tarayıcıda oturum açma + onay için gereken süre (Orca: 180 sn).
    static let loginTimeout: TimeInterval = 180
    static let statusTimeout: TimeInterval = 20
    static let binaryName = "claude"

    struct Result: Sendable, Equatable {
        let identity: ClaudeIdentity
        let snapshot: ClaudeAuthSurface.Snapshot
    }

    private let runner: any EnvironmentProcessRunning
    private let locator: any BinaryLocating
    private let keychain: any KeychainAccessing
    private let user: String
    private let temporaryDirectory: URL

    init(
        runner: any EnvironmentProcessRunning,
        locator: any BinaryLocating,
        keychain: any KeychainAccessing,
        user: String = ClaudeAuthLocations.keychainUser(),
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) {
        self.runner = runner
        self.locator = locator
        self.keychain = keychain
        self.user = user
        self.temporaryDirectory = temporaryDirectory
    }

    func run(environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> Result {
        guard let binary = await locator.locate(Self.binaryName) else {
            throw LumiError.cliNotFound(binary: Self.binaryName)
        }
        let configDir = try makeTemporaryConfigDir()
        // Kullanıcının düz servisteki kaydı: login sırasında CLI oraya yazarsa
        // sonunda eski hâli geri koyabilmek için.
        let previousLegacy = await keychain.password(
            service: ClaudeAuthLocations.legacyKeychainService, account: user
        )
        defer { try? FileManager.default.removeItem(at: configDir) }

        var childEnvironment = environment
        childEnvironment["CLAUDE_CONFIG_DIR"] = configDir.path

        let login = await runner.run(
            binary,
            arguments: ["auth", "login", "--claudeai"],
            environment: childEnvironment,
            timeout: Self.loginTimeout
        )
        guard let login else {
            await restoreLegacyKeychain(previousLegacy, temporaryConfigDir: configDir.path)
            throw LumiError.claudeAccountFailed(
                operation: "login", detail: "sign-in timed out or was cancelled"
            )
        }
        guard login.exitCode == 0 else {
            await restoreLegacyKeychain(previousLegacy, temporaryConfigDir: configDir.path)
            throw LumiError.claudeAccountFailed(
                operation: "login", detail: Self.detail(of: login)
            )
        }

        let status = await runner.run(
            binary,
            arguments: ["auth", "status", "--json"],
            environment: childEnvironment,
            timeout: Self.statusTimeout
        )
        // Yakalama temizlikten ÖNCE: geçici dizine ait keychain kaydı
        // silindikten sonra kimlik bilgisi okunamazdı.
        let snapshot = await capture(configDir: configDir, previousLegacy: previousLegacy)
        await restoreLegacyKeychain(previousLegacy, temporaryConfigDir: configDir.path)
        guard ClaudeIdentity.isValidCredentials(snapshot.credentialsJSON) else {
            throw LumiError.claudeAccountFailed(
                operation: "login", detail: "sign-in finished but no credentials were captured"
            )
        }
        let identity = ClaudeIdentity.resolve(
            statusJSON: status?.exitCode == 0 ? status?.stdout : nil,
            oauthAccountJSON: snapshot.oauthAccountJSON,
            credentialsJSON: snapshot.credentialsJSON
        )
        guard identity.email != nil else {
            throw LumiError.claudeAccountFailed(
                operation: "login", detail: "sign-in finished but the account email could not be read"
            )
        }
        return Result(identity: identity, snapshot: snapshot)
    }

    // MARK: - Yakalama

    /// Kapsanmış (geçici dizine ait) keychain kaydı → düz servisteki DEĞİŞMİŞ
    /// kayıt → geçici dizindeki dosya. Ortadaki adım şart: CLI eski sürümse
    /// düz servise yazar, ama oradaki değer değişmediyse o kullanıcının kendi
    /// eski oturumudur, yeni hesap değil.
    private func capture(
        configDir: URL, previousLegacy: String?
    ) async -> ClaudeAuthSurface.Snapshot {
        var credentials = await keychain.password(
            service: ClaudeAuthLocations.scopedKeychainService(configDir: configDir.path),
            account: user
        )
        if credentials == nil {
            let legacy = await keychain.password(
                service: ClaudeAuthLocations.legacyKeychainService, account: user
            )
            if let legacy, legacy != previousLegacy { credentials = legacy }
        }
        if credentials == nil {
            let file = configDir.appendingPathComponent(ClaudeAuthLocations.credentialsFileName)
            credentials = FileManager.default.contents(atPath: file.path)
                .map { String(decoding: $0, as: UTF8.self) }
        }
        return ClaudeAuthSurface.Snapshot(
            credentialsJSON: credentials,
            oauthAccountJSON: readOauthAccount(configDir: configDir)
        )
    }

    private func readOauthAccount(configDir: URL) -> String? {
        for name in [".claude.json", ".config.json"] {
            let path = configDir.appendingPathComponent(name).path
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["oauthAccount"] else { continue }
            return ClaudeAuthSurface.encode(value)
        }
        return nil
    }

    /// Login'in yan etkilerini temizler: geçici dizine ait kayıt silinir,
    /// kullanıcının düz servisteki kaydı eski hâline döner.
    private func restoreLegacyKeychain(_ previous: String?, temporaryConfigDir: String) async {
        try? await keychain.deletePassword(
            service: ClaudeAuthLocations.scopedKeychainService(configDir: temporaryConfigDir),
            account: user
        )
        let current = await keychain.password(
            service: ClaudeAuthLocations.legacyKeychainService, account: user
        )
        guard current != previous else { return }
        if let previous {
            try? await keychain.setPassword(
                previous, service: ClaudeAuthLocations.legacyKeychainService, account: user
            )
        } else {
            try? await keychain.deletePassword(
                service: ClaudeAuthLocations.legacyKeychainService, account: user
            )
        }
    }

    private func makeTemporaryConfigDir() throws -> URL {
        let url = temporaryDirectory
            .appendingPathComponent("lumi-claude-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private static func detail(of output: ProcessOutput) -> String {
        let text = [output.stderr, output.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "exit \(output.exitCode)"
        return String(text.suffix(300))
    }
}
