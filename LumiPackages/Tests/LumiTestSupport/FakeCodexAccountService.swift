import LumiKit

public actor FakeCodexAccountService: CodexAccountServicing {
    private var snapshot: CodexAccountsSnapshot
    private var home: String

    public init(snapshot: CodexAccountsSnapshot = .empty, home: String = "/tmp/fake-codex-home") {
        self.snapshot = snapshot
        self.home = home
    }

    public func accounts() async -> CodexAccountsSnapshot { snapshot }
    public func syncActiveSelection() async {}
    public func selectedHome() async -> String { home }
    public func cancelPendingLogin() async {}
    public func addAccount() async throws -> CodexAccountsSnapshot { snapshot }
    public func reauthenticate(accountID: String) async throws -> CodexAccountsSnapshot { snapshot }
    public func removeAccount(accountID: String) async throws -> CodexAccountsSnapshot {
        let accounts = snapshot.accounts.filter { $0.id != accountID }
        let selection: CodexAccountSelection = snapshot.selection == .account(accountID)
            ? .systemDefault : snapshot.selection
        snapshot = CodexAccountsSnapshot(accounts: accounts, selection: selection)
        return snapshot
    }
    public func select(_ selection: CodexAccountSelection) async throws -> CodexAccountsSnapshot {
        snapshot = CodexAccountsSnapshot(accounts: snapshot.accounts, selection: selection)
        return snapshot
    }
}
