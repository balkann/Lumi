import Foundation

public protocol CodexAccountServicing: Sendable {
    func accounts() async -> CodexAccountsSnapshot
    func syncActiveSelection() async
    func addAccount() async throws -> CodexAccountsSnapshot
    func cancelPendingLogin() async
    func reauthenticate(accountID: String) async throws -> CodexAccountsSnapshot
    func removeAccount(accountID: String) async throws -> CodexAccountsSnapshot
    func select(_ selection: CodexAccountSelection) async throws -> CodexAccountsSnapshot
    /// Effective home for new Codex processes and usage probes.
    func selectedHome() async -> String
}

public struct CodexAccountsSnapshot: Sendable, Equatable {
    public let accounts: [CodexAccount]
    public let selection: CodexAccountSelection
    public let systemDefaultEmail: String?

    public init(
        accounts: [CodexAccount],
        selection: CodexAccountSelection,
        systemDefaultEmail: String? = nil
    ) {
        self.accounts = accounts
        self.selection = selection
        self.systemDefaultEmail = systemDefaultEmail
    }

    public static let empty = CodexAccountsSnapshot(accounts: [], selection: .systemDefault)

    public var activeAccount: CodexAccount? {
        selection.accountID.flatMap { id in accounts.first { $0.id == id } }
    }
}
