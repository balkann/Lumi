import Foundation
import LumiKit

/// Testte belirli olayları yayan chat kaynağı.
public final class FakeChatTranscriptSource: ChatTranscriptSourcing, @unchecked Sendable {
    private let events: [ChatMirrorEvent]
    public private(set) var requested: [(sessionID: String, repoPath: String)] = []

    public init(events: [ChatMirrorEvent]) { self.events = events }

    public func stream(sessionID: String, repoPath: String) -> AsyncStream<ChatMirrorEvent> {
        requested.append((sessionID, repoPath))
        let events = self.events
        return AsyncStream { continuation in
            for e in events { continuation.yield(e) }
            continuation.finish()
        }
    }
}
