import Foundation
import LumiKit

/// Testte belirli olayları yayan chat kaynağı.
public final class FakeChatTranscriptSource: ChatTranscriptSourcing, @unchecked Sendable {
    private let events: [ChatMirrorEvent]
    private let keepOpen: Bool
    public private(set) var requested: [(sessionID: String, repoPath: String)] = []

    public init(events: [ChatMirrorEvent], keepOpen: Bool = false) {
        self.events = events
        self.keepOpen = keepOpen
    }

    public func stream(sessionID: String, repoPath: String) -> AsyncStream<ChatMirrorEvent> {
        requested.append((sessionID, repoPath))
        let events = self.events
        let keepOpen = self.keepOpen
        return AsyncStream { continuation in
            for e in events { continuation.yield(e) }
            if !keepOpen { continuation.finish() }
        }
    }
}
