import Foundation
import LumiKit

/// Owns isolated Codex homes and the selection used by future Codex processes.
public actor CodexAccountService: CodexAccountServicing {
    private static let loginTimeout: TimeInterval = 180

    private let config: any ConfigServicing
    private let root: URL
    private let systemDefaultHome: URL
    private let runtimeResources: CodexManagedRuntimeResources
    private let runner: any EnvironmentProcessRunning
    private let locator: any BinaryLocating
    private let now: @Sendable () -> Date
    private var pendingLogin: Task<CodexAuthIdentity, Error>?

    public init(
        config: any ConfigServicing,
        paths: LumiPaths,
        runner: any EnvironmentProcessRunning = SystemProcessRunner(),
        locator: any BinaryLocating = SystemBinaryLocator(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        root = paths.codexAccountsDir
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let defaultHome = environment["CODEX_HOME"].map(URL.init(fileURLWithPath:)) ?? fallback
        systemDefaultHome = defaultHome
        runtimeResources = CodexManagedRuntimeResources(
            systemHome: defaultHome,
            hookScriptPath: paths.configDir
                .appendingPathComponent(AgentHookScript.directoryName)
                .appendingPathComponent(AgentHookScript.fileName(for: .codex)).path
        )
        self.runner = runner
        self.locator = locator
        self.now = now
    }

    public func accounts() async -> CodexAccountsSnapshot {
        let value = await config.config()
        return CodexAccountsSnapshot(
            accounts: value.codexAccounts.sorted { $0.createdAt < $1.createdAt },
            selection: value.codexAccountSelection,
            systemDefaultEmail: identity(at: systemDefaultHome)?.email
        )
    }

    public func selectedHome() async -> String {
        let snapshot = await accounts()
        guard let account = snapshot.activeAccount, let home = home(for: account.id),
              isTrustedManagedHome(home, accountID: account.id) else {
            return systemDefaultHome.path
        }
        return home.path
    }

    public func resolvedResumeHome(_ persistedHome: String?) async -> String? {
        guard let persistedHome, !persistedHome.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: persistedHome).standardizedFileURL
        if candidate.path == systemDefaultHome.standardizedFileURL.path {
            return systemDefaultHome.path
        }
        let value = await config.config()
        for account in value.codexAccounts {
            guard let managed = home(for: account.id),
                  candidate.path == managed.standardizedFileURL.path,
                  isTrustedManagedHome(managed, accountID: account.id),
                  FileManager.default.fileExists(atPath: managed.path) else { continue }
            return managed.path
        }
        return nil
    }

    public func syncActiveSelection() async {
        let snapshot = await accounts()
        guard let account = snapshot.activeAccount, let home = home(for: account.id),
              isTrustedManagedHome(home, accountID: account.id) else { return }
        let hooksEnabled = await config.config().agentHooksEnabled
        try? runtimeResources.materialize(into: home, hooksEnabled: hooksEnabled)
    }

    public func syncManagedHooks(enabled: Bool) async {
        let value = await config.config()
        for account in value.codexAccounts {
            guard let managed = home(for: account.id),
                  isTrustedManagedHome(managed, accountID: account.id),
                  FileManager.default.fileExists(atPath: managed.path) else { continue }
            try? runtimeResources.syncHooks(into: managed, enabled: enabled)
        }
    }

    public func addAccount() async throws -> CodexAccountsSnapshot {
        let id = UUID().uuidString
        guard let home = home(for: id) else {
            throw LumiError.codexAccountFailed(operation: "add", detail: "invalid account id")
        }
        try await prepare(home: home)
        do {
            let identity = try await runLogin(home: home)
            let existing = await config.config().codexAccounts
            guard !existing.contains(where: {
                $0.email.caseInsensitiveCompare(identity.email ?? "") == .orderedSame
                    && $0.workspaceName == identity.workspaceName
            }) else {
                throw LumiError.codexAccountFailed(
                    operation: "add", detail: "\(identity.email ?? "This account") is already added."
                )
            }
            let timestamp = now()
            let account = CodexAccount(
                id: id,
                email: identity.email!,
                workspaceName: identity.workspaceName,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastAuthenticatedAt: timestamp
            )
            try await config.updateConfig {
                $0.codexAccounts.append(account)
                $0.codexAccountSelection = .account(id)
            }
            return await accounts()
        } catch {
            if isTrustedManagedHome(home, accountID: id) {
                try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
            }
            throw error
        }
    }

    public func cancelPendingLogin() async {
        pendingLogin?.cancel()
    }

    public func reauthenticate(accountID: String) async throws -> CodexAccountsSnapshot {
        let snapshot = await accounts()
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }),
              let home = home(for: accountID) else {
            throw LumiError.codexAccountFailed(operation: "re-authenticate", detail: "account no longer exists")
        }
        try await prepare(home: home)
        let authFile = home.appendingPathComponent("auth.json")
        let previousAuth = FileManager.default.contents(atPath: authFile.path)
        let identity: CodexAuthIdentity
        do {
            identity = try await runLogin(home: home)
            guard identity.email?.caseInsensitiveCompare(account.email) == .orderedSame else {
                throw LumiError.codexAccountFailed(
                    operation: "re-authenticate",
                    detail: "signed in as \(identity.email ?? "an unknown account"), but this row belongs to \(account.email)"
                )
            }
        } catch {
            if let previousAuth { try? previousAuth.write(to: authFile, options: .atomic) }
            else { try? FileManager.default.removeItem(at: authFile) }
            throw error
        }
        let timestamp = now()
        try await config.updateConfig { value in
            guard let index = value.codexAccounts.firstIndex(where: { $0.id == accountID }) else { return }
            value.codexAccounts[index].workspaceName = identity.workspaceName
            value.codexAccounts[index].updatedAt = timestamp
            value.codexAccounts[index].lastAuthenticatedAt = timestamp
        }
        return await accounts()
    }

    public func removeAccount(accountID: String) async throws -> CodexAccountsSnapshot {
        let snapshot = await accounts()
        guard snapshot.accounts.contains(where: { $0.id == accountID }) else { return snapshot }
        guard let home = home(for: accountID), isTrustedManagedHome(home, accountID: accountID) else {
            throw LumiError.codexAccountFailed(
                operation: "remove", detail: "the managed account directory is not trusted"
            )
        }
        try await config.updateConfig { value in
            value.codexAccounts.removeAll { $0.id == accountID }
            if value.codexAccountSelection == .account(accountID) {
                value.codexAccountSelection = .systemDefault
            }
        }
        let accountDirectory = home.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: accountDirectory.path) {
            try FileManager.default.removeItem(at: accountDirectory)
        }
        return await accounts()
    }

    public func select(_ selection: CodexAccountSelection) async throws -> CodexAccountsSnapshot {
        let snapshot = await accounts()
        if case .account(let id) = selection {
            guard snapshot.accounts.contains(where: { $0.id == id }), let home = home(for: id),
                  isTrustedManagedHome(home, accountID: id),
                  FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path) else {
                throw LumiError.codexAccountFailed(
                    operation: "switch", detail: "this account has no credentials — re-authenticate it"
                )
            }
            let hooksEnabled = await config.config().agentHooksEnabled
            try runtimeResources.materialize(into: home, hooksEnabled: hooksEnabled)
        }
        try await config.updateConfig { $0.codexAccountSelection = selection }
        return await accounts()
    }

    private func runLogin(home: URL) async throws -> CodexAuthIdentity {
        guard let binary = await locator.locate("codex") else {
            throw LumiError.cliNotFound(binary: "codex")
        }
        let task = Task<CodexAuthIdentity, Error> { [runner] in
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = home.path
            let output = await runner.run(
                binary,
                arguments: ["login"],
                environment: environment,
                options: ProcessLaunchOptions(keepsStandardInputOpen: true, terminatesChildProcesses: true),
                timeout: Self.loginTimeout
            )
            guard let output else {
                let detail = Task.isCancelled ? "sign-in was cancelled" : "sign-in timed out or was cancelled"
                throw LumiError.codexAccountFailed(operation: "login", detail: detail)
            }
            guard output.exitCode == 0 else {
                let detail = (output.stderr.isEmpty ? output.stdout : output.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LumiError.codexAccountFailed(
                    operation: "login", detail: detail.isEmpty ? "Codex login failed" : detail
                )
            }
            let auth = home.appendingPathComponent("auth.json")
            guard let data = FileManager.default.contents(atPath: auth.path),
                  let identity = CodexAuthIdentity.read(from: data), identity.email != nil else {
                throw LumiError.codexAccountFailed(
                    operation: "login", detail: "sign-in finished but the account email could not be read"
                )
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
            return identity
        }
        pendingLogin = task
        defer { pendingLogin = nil }
        return try await task.value
    }

    private func prepare(home: URL) async throws {
        let id = home.deletingLastPathComponent().lastPathComponent
        for url in [root, root.appendingPathComponent(id), home]
        where FileManager.default.fileExists(atPath: url.path) {
            guard !isSymbolicLink(url) else {
                throw LumiError.codexAccountFailed(
                    operation: "prepare", detail: "the managed account directory is not trusted"
                )
            }
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        guard isTrustedManagedHome(home, accountID: id) else {
            throw LumiError.codexAccountFailed(
                operation: "prepare", detail: "the managed account directory is not trusted"
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        let hooksEnabled = await config.config().agentHooksEnabled
        try runtimeResources.materialize(into: home, hooksEnabled: hooksEnabled)
    }

    private func identity(at home: URL) -> CodexAuthIdentity? {
        FileManager.default.contents(atPath: home.appendingPathComponent("auth.json").path)
            .flatMap(CodexAuthIdentity.read)
    }

    private func home(for id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    private func isTrustedManagedHome(_ home: URL, accountID: String) -> Bool {
        guard let expected = self.home(for: accountID),
              home.standardizedFileURL.path == expected.standardizedFileURL.path else { return false }
        for url in [root, root.appendingPathComponent(accountID), home]
        where FileManager.default.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { return false }
        }
        return true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
