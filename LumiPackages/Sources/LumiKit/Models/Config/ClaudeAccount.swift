import Foundation

/// Lumi'nin yönettiği bir Claude hesabı (karar 56 — Orca'nın
/// `ClaudeManagedAccount` paritesi).
///
/// **Burada kimlik bilgisi YOKTUR.** `config.json`'a yalnız kimliği tanıtan
/// alanlar yazılır; OAuth credentials'ı macOS Keychain'de (servis
/// `Lumi Claude Managed Credentials`, hesap = `id`), `oauthAccount` bloğu ise
/// `~/.lumi/claude-accounts/<id>/auth/oauth-account.json` içinde (0600) yaşar.
/// Bir token'ın config'e sızmaması bu tipin boyut sözleşmesidir.
public struct ClaudeAccount: Sendable, Equatable, Identifiable {
    /// Kalıcı kimlik (UUID string). Keychain hesabı ve managed auth dizini
    /// adıdır — e-posta değişse bile sabit kalır.
    public let id: String
    public var email: String
    public var organizationUUID: String?
    public var organizationName: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastAuthenticatedAt: Date

    public init(
        id: String,
        email: String,
        organizationUUID: String? = nil,
        organizationName: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastAuthenticatedAt: Date
    ) {
        self.id = id
        self.email = email
        self.organizationUUID = organizationUUID
        self.organizationName = organizationName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }

    /// Aynı hesabın iki kez eklenmesini engelleyen kimlik ölçütü (Orca'nın
    /// `findDuplicateClaudeAccount`'ı): e-posta + organizasyon çifti.
    public func isSameIdentity(email otherEmail: String, organizationUUID otherOrg: String?) -> Bool {
        email.caseInsensitiveCompare(otherEmail) == .orderedSame
            && (organizationUUID ?? "") == (otherOrg ?? "")
    }
}

/// Hesap seçimi: yönetilen bir hesap ya da kullanıcının kendi `~/.claude`
/// oturumu (`systemDefault`). Seçim `config.json`'da hesabın id'si olarak,
/// sistem varsayılanı ise anahtarın yokluğu/`null` olarak durur.
public enum ClaudeAccountSelection: Sendable, Equatable {
    case systemDefault
    case account(String)

    public init(accountID: String?) {
        self = accountID.map(Self.account) ?? .systemDefault
    }

    public var accountID: String? {
        switch self {
        case .systemDefault: return nil
        case let .account(id): return id
        }
    }
}
