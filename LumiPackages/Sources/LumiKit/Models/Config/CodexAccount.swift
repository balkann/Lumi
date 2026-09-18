import Foundation

/// A Codex login managed by Lumi. Credentials remain in the account's isolated
/// `CODEX_HOME`; persisted configuration contains identity metadata only.
public struct CodexAccount: Sendable, Equatable, Identifiable {
    public let id: String
    public var email: String
    public var workspaceName: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastAuthenticatedAt: Date

    public init(
        id: String,
        email: String,
        workspaceName: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastAuthenticatedAt: Date
    ) {
        self.id = id
        self.email = email
        self.workspaceName = workspaceName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }
}

public enum CodexAccountSelection: Sendable, Equatable {
    case systemDefault
    case account(String)

    public init(accountID: String?) {
        self = accountID.map(Self.account) ?? .systemDefault
    }

    public var accountID: String? {
        switch self {
        case .systemDefault: nil
        case .account(let id): id
        }
    }
}
