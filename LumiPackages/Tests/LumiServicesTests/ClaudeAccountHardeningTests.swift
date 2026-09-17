import Foundation
import LumiKit
import LumiTestSupport
import XCTest
@testable import LumiServices

/// Karar 56 sertleştirmesi: kullanıcının KENDİ Claude oturumunu kaybettiren
/// ya da yanlış token yazan yolların hepsi burada kapalı tutulur.
final class ClaudeAccountHardeningTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var keychain: FakeKeychain!
    private var runner: FakeEnvironmentProcessRunner!
    private var locator: FakeBinaryLocator!
    private var config: FakeConfigService!
    private let user = "tester"

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumi-hardening-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        keychain = FakeKeychain()
        runner = FakeEnvironmentProcessRunner()
        locator = FakeBinaryLocator(paths: ["claude": "/usr/local/bin/claude"])
        config = FakeConfigService()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Kurulum

    private var runtimePaths: ClaudeRuntimeAuthPaths {
        ClaudeAuthLocations.runtime(
            homeDirectory: home.path, environment: [:],
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    private var scopedService: String {
        ClaudeAuthLocations.scopedKeychainService(configDir: runtimePaths.configDir)
    }

    private func makeService() -> ClaudeAccountService {
        ClaudeAccountService(
            config: config,
            store: ClaudeManagedAuthStore(
                keychain: keychain, root: root.appendingPathComponent("claude-accounts")
            ),
            surface: ClaudeAuthSurface(keychain: keychain, paths: runtimePaths, user: user),
            login: ClaudeLoginSession(
                runner: runner, locator: locator, keychain: keychain, user: user,
                temporaryDirectory: root.appendingPathComponent("tmp")
            ),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private static func credentials(_ token: String, email: String? = nil, expiresAt: Double? = nil) -> String {
        var oauth: [String: Any] = ["accessToken": token, "refreshToken": "r-\(token)"]
        if let email { oauth["email"] = email }
        if let expiresAt { oauth["expiresAt"] = expiresAt }
        // `sortedKeys`: aynı girdi her çağrıda AYNI metni üretsin, yoksa
        // karşılaştırmalar sözlük sırasına göre rastgele kırılır.
        let data = try! JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func scriptLogin(email: String, token: String) async {
        await runner.setResult(
            ProcessOutput(exitCode: 0, stdout: #"{"email":"\#(email)"}"#, stderr: ""),
            for: "auth status"
        )
        let keychain = keychain!
        let user = user
        await runner.setSideEffect(for: "auth login") { invocation in
            guard let configDir = invocation.configDir else { return }
            try? await keychain.setPassword(
                Self.credentials(token, email: email),
                service: ClaudeAuthLocations.scopedKeychainService(configDir: configDir),
                account: user
            )
            let object = ["oauthAccount": ["emailAddress": email]]
            try? JSONSerialization.data(withJSONObject: object).write(
                to: URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
            )
        }
    }

    @discardableResult
    private func addAccount(email: String, token: String) async throws -> ClaudeAccount {
        await scriptLogin(email: email, token: token)
        let snapshot = try await makeService().addAccount()
        return try XCTUnwrap(snapshot.accounts.first { $0.email == email })
    }

    private func seedSystemLogin(_ credentials: String) async {
        await keychain.seed(
            credentials, service: ClaudeAuthLocations.legacyKeychainService, account: user
        )
    }

    // MARK: - Keychain okunamadığında kullanıcının oturumu silinmez

    /// Kilitli keychain "kayıt yok" sayılırsa geçiş, kullanıcının kendi
    /// oturumunu yakalayamadan devam eder ve dönüşte yüzeyi boşaltırdı.
    func testSwitchIsRefusedWhenTheSurfaceCannotBeRead() async throws {
        await seedSystemLogin(Self.credentials("system", email: "me@example.com"))
        let account = try await addAccount(email: "dev@example.com", token: "token-1")
        await keychain.failReads(service: scopedService)

        do {
            _ = try await makeService().select(.account(account.id))
            XCTFail("okunamayan yüzeyde geçiş yapılmamalı")
        } catch {
            let live = await keychain.stored(
                service: ClaudeAuthLocations.legacyKeychainService, account: user
            )
            XCTAssertEqual(
                live, Self.credentials("system", email: "me@example.com"),
                "kullanıcının oturumu olduğu gibi kalmalı"
            )
            let selection = await config.config().claudeAccountSelection
            XCTAssertEqual(selection, .systemDefault)
        }
    }

    /// Yedek Keychain'den okunamıyorsa `System default` yüzeyi BOŞALTMAMALI.
    func testRestoreIsRefusedWhenTheSavedSystemLoginCannotBeRead() async throws {
        let system = Self.credentials("system", email: "me@example.com")
        await seedSystemLogin(system)
        let account = try await addAccount(email: "dev@example.com", token: "token-1")
        let service = makeService()
        _ = try await service.select(.account(account.id))

        await keychain.failReads(service: ClaudeAuthLocations.managedKeychainService)

        do {
            _ = try await service.select(.systemDefault)
            XCTFail("yedek okunamıyorken geri yükleme yapılmamalı")
        } catch {
            let live = await keychain.stored(service: scopedService, account: user)
            XCTAssertEqual(live, Self.credentials("token-1", email: "dev@example.com"),
                           "yüzey boşaltılmamalı")
        }
    }

    // MARK: - Yarım kalan yakalama

    /// Yakalama sırasında Keychain yazımı reddedilirse snapshot TAMAMLANMAMIŞ
    /// sayılır; ikinci geçiş yönetilen bir hesabı "sistem varsayılanı" diye
    /// kaydetmez, kullanıcının gerçek oturumunu yeniden yakalar.
    func testIncompleteSnapshotIsRecapturedInsteadOfAdoptingAManagedAccount() async throws {
        let system = Self.credentials("system", email: "me@example.com")
        await seedSystemLogin(system)
        let first = try await addAccount(email: "one@example.com", token: "token-1")
        let second = try await addAccount(email: "two@example.com", token: "token-2")

        await keychain.failWrites(service: ClaudeAuthLocations.managedKeychainService)
        _ = try? await makeService().select(.account(first.id))
        await keychain.allowWrites(service: ClaudeAuthLocations.managedKeychainService)

        let service = makeService()
        _ = try await service.select(.account(second.id))
        _ = try await service.select(.systemDefault)

        let live = await keychain.stored(
            service: ClaudeAuthLocations.legacyKeychainService, account: user
        )
        XCTAssertEqual(live, system, "geri gelen oturum kullanıcının kendisininki olmalı")
    }

    // MARK: - Dışarıdan gelen login

    /// Kullanıcı terminalde elle kendi hesabına girdiyse, `System default`'a
    /// dönüş o TAZE oturumu eski snapshot'la ezmemeli.
    func testExternalLoginIsNotOverwrittenWhenReturningToSystemDefault() async throws {
        await seedSystemLogin(Self.credentials("system", email: "me@example.com"))
        let account = try await addAccount(email: "dev@example.com", token: "token-1")
        let service = makeService()
        _ = try await service.select(.account(account.id))

        let fresh = Self.credentials("fresh-personal", email: "me@example.com")
        await keychain.seed(fresh, service: scopedService, account: user)

        _ = try await service.select(.systemDefault)

        let live = await keychain.stored(service: scopedService, account: user)
        XCTAssertEqual(live, fresh, "elle açılan taze oturum korunmalı")
    }

    // MARK: - Geri okuma kimlik kapısı

    func testReadBackRejectsCredentialsThatCarryAnotherAccountsEmail() {
        let account = ClaudeAccount(
            id: UUID().uuidString, email: "dev@example.com",
            createdAt: .distantPast, updatedAt: .distantPast, lastAuthenticatedAt: .distantPast
        )
        let foreign = Self.credentials("x", email: "stranger@example.com")
        XCTAssertFalse(ClaudeAccountService.credentialsBelong(
            to: account, credentials: foreign,
            managed: ClaudeAuthSurface.Snapshot(credentialsJSON: nil, oauthAccountJSON: nil),
            live: ClaudeAuthSurface.Snapshot(credentialsJSON: foreign, oauthAccountJSON: nil)
        ))
    }

    /// Ne blob'da kimlik ne de yönetilen tarafta `oauthAccount` varsa
    /// doğrulanamaz sayılır ve YAZILMAZ (eski kod bu durumda yazıyordu).
    func testReadBackRejectsUnverifiableCredentials() {
        let account = ClaudeAccount(
            id: UUID().uuidString, email: "dev@example.com",
            createdAt: .distantPast, updatedAt: .distantPast, lastAuthenticatedAt: .distantPast
        )
        let anonymous = Self.credentials("x")
        XCTAssertFalse(ClaudeAccountService.credentialsBelong(
            to: account, credentials: anonymous,
            managed: ClaudeAuthSurface.Snapshot(credentialsJSON: nil, oauthAccountJSON: nil),
            live: ClaudeAuthSurface.Snapshot(credentialsJSON: anonymous, oauthAccountJSON: nil)
        ))
    }

    func testReadBackAcceptsTheAccountsOwnCredentials() {
        let account = ClaudeAccount(
            id: UUID().uuidString, email: "Dev@Example.com",
            createdAt: .distantPast, updatedAt: .distantPast, lastAuthenticatedAt: .distantPast
        )
        let own = Self.credentials("x", email: "dev@example.com")
        XCTAssertTrue(ClaudeAccountService.credentialsBelong(
            to: account, credentials: own,
            managed: ClaudeAuthSurface.Snapshot(credentialsJSON: nil, oauthAccountJSON: nil),
            live: ClaudeAuthSurface.Snapshot(credentialsJSON: own, oauthAccountJSON: nil)
        ))
    }

    // MARK: - Açılış senkronizasyonu

    /// Açılışta CLI'ın tazelediği token önce depoya alınır; eski blob yüzeye
    /// geri yazılmaz (tek kullanımlık refresh token'ı tüketmemek için).
    func testStartupSyncPersistsRefreshedTokensInsteadOfOverwritingThem() async throws {
        let account = try await addAccount(email: "dev@example.com", token: "token-1")
        let service = makeService()
        _ = try await service.select(.account(account.id))

        let refreshed = Self.credentials("token-1-refreshed", email: "dev@example.com")
        await keychain.seed(refreshed, service: scopedService, account: user)

        await makeService().syncActiveSelection()

        let stored = await keychain.stored(
            service: ClaudeAuthLocations.managedKeychainService, account: account.id
        )
        let live = await keychain.stored(service: scopedService, account: user)
        XCTAssertEqual(stored, refreshed, "tazelenen token depoya alınmalı")
        XCTAssertEqual(live, refreshed, "yüzeye bayat blob yazılmamalı")
    }

    /// Yüzey zaten doğru kopyayı taşıyorsa açılışta hiçbir yazma yapılmaz.
    func testStartupSyncWritesNothingWhenTheSurfaceAlreadyMatches() async throws {
        let account = try await addAccount(email: "dev@example.com", token: "token-1")
        _ = try await makeService().select(.account(account.id))
        let writesBefore = await keychain.writes.count

        await makeService().syncActiveSelection()

        let writesAfter = await keychain.writes.count
        XCTAssertEqual(writesAfter, writesBefore, "gereksiz yazım yok")
    }

    // MARK: - Eski blob yeniyi ezmesin

    func testReadBackKeepsTheNewerCredentialsWhenTheSurfaceIsOlder() async throws {
        let account = try await addAccount(email: "dev@example.com", token: "token-1")
        let service = makeService()
        _ = try await service.select(.account(account.id))
        let newer = Self.credentials("newer", email: "dev@example.com", expiresAt: 2_000)
        try await keychain.setPassword(
            newer, service: ClaudeAuthLocations.managedKeychainService, account: account.id
        )
        let older = Self.credentials("older", email: "dev@example.com", expiresAt: 1_000)
        await keychain.seed(older, service: scopedService, account: user)

        await makeService().syncActiveSelection()

        let stored = await keychain.stored(
            service: ClaudeAuthLocations.managedKeychainService, account: account.id
        )
        XCTAssertEqual(stored, newer, "eski blob yeninin üstüne yazılmamalı")
    }
}
