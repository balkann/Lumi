import Foundation
import LumiKit

/// Claude hesaplarının tek yetkili sahibi (karar 56).
///
/// Sıralı erişim şart olduğu için `actor`: iki hesap değişimi iç içe girerse
/// yüzeye yarım kimlik bilgisi yazılır. Hesap listesi `config.json`'da,
/// token'lar `ClaudeManagedAuthStore`'da (Keychain) yaşar; bu tip ikisini
/// tutarlı tutar.
///
/// **Bilinçli kapsam dışı (Orca'da var):** proaktif OAuth token yenileme.
/// Orca, tek kullanımlık refresh token'ı kendi döndürüp saklıyor; Lumi
/// yenilemeyi CLI'a bırakır ve döndürülen token'ı "geri okuma" ile yönetilen
/// depoya yazar. Sonuç: süresi dolmuş bir hesapta kullanım göstergesi, o hesap
/// altında bir terminal açılana kadar hata verebilir.
public actor ClaudeAccountService: ClaudeAccountServicing {
    private let config: any ConfigServicing
    private let store: ClaudeManagedAuthStore
    private let surface: ClaudeAuthSurface
    private let login: ClaudeLoginSession
    private let now: @Sendable () -> Date
    private var pendingLogin: Task<ClaudeLoginSession.Result, Error>?

    public init(
        config: any ConfigServicing,
        paths: LumiPaths,
        keychain: any KeychainAccessing = SecurityKeychain(),
        runner: any EnvironmentProcessRunning = SystemProcessRunner(),
        locator: any BinaryLocating = SystemBinaryLocator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            config: config,
            store: ClaudeManagedAuthStore(keychain: keychain, root: paths.claudeAccountsDir),
            surface: ClaudeAuthSurface(keychain: keychain),
            login: ClaudeLoginSession(runner: runner, locator: locator, keychain: keychain),
            now: now
        )
    }

    init(
        config: any ConfigServicing,
        store: ClaudeManagedAuthStore,
        surface: ClaudeAuthSurface,
        login: ClaudeLoginSession,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.store = store
        self.surface = surface
        self.login = login
        self.now = now
    }

    // MARK: - Okuma

    public func accounts() async -> ClaudeAccountsSnapshot {
        let config = await config.config()
        return ClaudeAccountsSnapshot(
            accounts: config.claudeAccounts.sorted { $0.createdAt < $1.createdAt },
            selection: config.claudeAccountSelection
        )
    }

    /// Uygulama açılışında çağrılır: seçili hesabın kimlik bilgisi yüzeyde
    /// değilse (başka bir araç üzerine yazmış olabilir) yeniden materialize
    /// edilir. Hata yutulur — açılış bir hesap sorunu yüzünden bloklanmaz.
    public func syncActiveSelection() async {
        let snapshot = await accounts()
        guard let account = snapshot.activeAccount else { return }
        do {
            try await materialize(account)
        } catch {
            // Sessiz: kullanıcı hesabı Settings'ten yeniden seçerse hata görünür.
        }
    }

    // MARK: - Ekleme / yeniden doğrulama

    public func addAccount() async throws -> ClaudeAccountsSnapshot {
        let result = try await runLogin()
        let email = result.identity.email ?? ""
        let existing = await config.config().claudeAccounts
        guard !existing.contains(where: {
            $0.isSameIdentity(email: email, organizationUUID: result.identity.organizationUUID)
        }) else {
            throw LumiError.claudeAccountFailed(
                operation: "add", detail: "\(email) is already added."
            )
        }
        let timestamp = now()
        let account = ClaudeAccount(
            id: UUID().uuidString,
            email: email,
            organizationUUID: result.identity.organizationUUID,
            organizationName: result.identity.organizationName,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastAuthenticatedAt: timestamp
        )
        try await store.write(result.snapshot, accountID: account.id)
        try await config.updateConfig { $0.claudeAccounts.append(account) }
        return await accounts()
    }

    public func reauthenticate(accountID: String) async throws -> ClaudeAccountsSnapshot {
        let snapshot = await accounts()
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
            throw LumiError.claudeAccountFailed(operation: "re-authenticate", detail: "account no longer exists")
        }
        let result = try await runLogin()
        let email = result.identity.email ?? account.email
        guard account.isSameIdentity(email: email, organizationUUID: result.identity.organizationUUID)
            || result.identity.organizationUUID == nil else {
            throw LumiError.claudeAccountFailed(
                operation: "re-authenticate",
                detail: "signed in as \(email), but this row belongs to \(account.email)"
            )
        }
        try await store.write(result.snapshot, accountID: accountID)
        let timestamp = now()
        try await config.updateConfig { config in
            guard let index = config.claudeAccounts.firstIndex(where: { $0.id == accountID }) else { return }
            config.claudeAccounts[index].email = email
            config.claudeAccounts[index].organizationUUID = result.identity.organizationUUID
            config.claudeAccounts[index].organizationName = result.identity.organizationName
            config.claudeAccounts[index].updatedAt = timestamp
            config.claudeAccounts[index].lastAuthenticatedAt = timestamp
        }
        // Aktif hesap yeniden doğrulandıysa taze token hemen yüzeye iner.
        if snapshot.selection == .account(accountID) {
            try await surface.write(result.snapshot)
        }
        return await accounts()
    }

    public func cancelPendingLogin() async {
        pendingLogin?.cancel()
    }

    // MARK: - Silme / seçim

    public func removeAccount(accountID: String) async throws -> ClaudeAccountsSnapshot {
        let snapshot = await accounts()
        guard snapshot.accounts.contains(where: { $0.id == accountID }) else { return snapshot }
        // Aktif hesabı silmek önce yüzeyi sistem varsayılanına döndürür;
        // aksi halde silinmiş bir hesabın token'ı yüzeyde kalırdı.
        if snapshot.selection == .account(accountID) {
            try await restoreSystemDefault()
            try await config.updateConfig { $0.claudeAccountSelection = .systemDefault }
        }
        try await store.remove(accountID: accountID)
        try await config.updateConfig { config in
            config.claudeAccounts.removeAll { $0.id == accountID }
        }
        return await accounts()
    }

    public func select(_ selection: ClaudeAccountSelection) async throws -> ClaudeAccountsSnapshot {
        let snapshot = await accounts()
        guard selection != snapshot.selection else { return snapshot }
        // Ayrılmadan önce CLI'ın tazelediği token'ları hesabın kendi deposuna
        // geri yaz — yoksa bir sonraki geçişte bayat token materialize edilirdi.
        if let outgoing = snapshot.activeAccount {
            await readBackRefreshedCredentials(for: outgoing)
        }
        switch selection {
        case let .account(id):
            guard let account = snapshot.accounts.first(where: { $0.id == id }) else {
                throw LumiError.claudeAccountFailed(operation: "switch", detail: "account no longer exists")
            }
            try await materialize(account)
        case .systemDefault:
            try await restoreSystemDefault()
        }
        try await config.updateConfig { $0.claudeAccountSelection = selection }
        return await accounts()
    }

    // MARK: - Yüzey işlemleri

    private func materialize(_ account: ClaudeAccount) async throws {
        let managed = await store.readSnapshot(accountID: account.id)
        guard ClaudeIdentity.isValidCredentials(managed.credentialsJSON) else {
            throw LumiError.claudeAccountFailed(
                operation: "switch",
                detail: "\(account.email) has no stored credentials — re-authenticate it."
            )
        }
        // İlk yönetilen geçişte kullanıcının KENDİ oturumu saklanır.
        try await store.captureSystemDefaultIfNeeded(surface.read())
        try await surface.write(managed)
    }

    private func restoreSystemDefault() async throws {
        guard let snapshot = await store.systemDefaultSnapshot() else {
            // Yakalanmış bir varsayılan yoksa yüzeyi boşaltmak kullanıcıyı
            // hiç istemediği bir oturum kapatmaya sürüklerdi; olduğu gibi bırak.
            return
        }
        try await surface.write(snapshot)
        try await store.clearSystemDefaultSnapshot()
    }

    /// Yüzeydeki kimlik bilgisi yönetilen kopyadan farklıysa CLI onu
    /// tazelemiştir. Kimlik kanıtı olarak `oauthAccount` karşılaştırılır:
    /// kullanıcı terminalde elle başka bir hesaba geçtiyse o hesabın token'ını
    /// bizimkinin üstüne yazmayalım.
    private func readBackRefreshedCredentials(for account: ClaudeAccount) async {
        let managed = await store.readSnapshot(accountID: account.id)
        let live = await surface.read()
        guard let credentials = live.credentialsJSON,
              credentials != managed.credentialsJSON,
              ClaudeIdentity.isValidCredentials(credentials) else { return }
        if let managedOauth = managed.oauthAccountJSON, managedOauth != live.oauthAccountJSON {
            return
        }
        try? await store.write(
            ClaudeAuthSurface.Snapshot(
                credentialsJSON: credentials,
                oauthAccountJSON: managed.oauthAccountJSON ?? live.oauthAccountJSON
            ),
            accountID: account.id
        )
    }

    private func runLogin() async throws -> ClaudeLoginSession.Result {
        if pendingLogin != nil {
            throw LumiError.claudeAccountFailed(operation: "login", detail: "a sign-in is already running")
        }
        let session = login
        let task = Task { try await session.run() }
        pendingLogin = task
        defer { pendingLogin = nil }
        return try await task.value
    }
}
