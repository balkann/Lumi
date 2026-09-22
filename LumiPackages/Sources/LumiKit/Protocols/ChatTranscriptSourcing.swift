import Foundation

/// Bir oturumun transcript'ini chat olaylarına çeviren kaynak sınırı.
/// RemoteService bunu enjekte alır (LumiRemote yalnız LumiKit'e bağlı).
public protocol ChatTranscriptSourcing: Sendable {
    /// İlk `.snapshot`, sonra dosya büyüdükçe `.append`. Consumer iptal edince biter.
    func stream(sessionID: String, repoPath: String) -> AsyncStream<ChatMirrorEvent>
}
