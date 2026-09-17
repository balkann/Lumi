import Foundation

/// Bir terminal sekmesinin ne tür bir oturum yürüttüğünü belirtir.
/// `.terminal` = klasik PTY; `.chat` = stream-json native chat (spec 2026-09-17 Faz 1).
public enum SessionKind: String, Sendable, Equatable {
    case terminal
    case chat
}

/// Bir chat oturumunun sabit kimlik bilgileri (değişmez metadata).
public struct ChatSessionMeta: Sendable, Identifiable, Equatable {
    public let id: String
    public let repoPath: String
    public let createdAt: Date

    public init(id: String, repoPath: String, createdAt: Date) {
        self.id = id
        self.repoPath = repoPath
        self.createdAt = createdAt
    }
}
