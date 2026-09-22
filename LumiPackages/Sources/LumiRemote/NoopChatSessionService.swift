import Foundation
import LumiKit

/// Eski testlerin `RemoteService` init çağrılarını bozmamak için varsayılan
/// no-op implementasyon. create/list/close/send/snapshots hepsi işlemsiz.
public struct NoopChatSessionService: ChatSessionServicing {
    public init() {}
    public func create(repoPath: String) async -> ChatSessionMeta {
        ChatSessionMeta(id: UUID().uuidString, repoPath: repoPath, createdAt: Date())
    }
    public func list() async -> [ChatSessionMeta] { [] }
    public func close(id: String) async {}
    public func send(id: String, text: String) async {}
    public func snapshots(id: String) async -> AsyncStream<ChatJournalState>? { nil }
}
