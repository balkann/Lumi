import Foundation
import LumiKit

/// Chat oturumlarını yöneten actor: her biri bir `StreamJsonAgentSession` (Faz 1).
/// In-memory; geçmiş claude transcript'inde kalıcı (spec Yol B Faz 2 §A).
public actor ChatSessionService: ChatSessionServicing {
    private let spawner: any StreamingProcessSpawning
    private let binaryLocator: any BinaryLocating
    private let environment: [String: String]
    private let makeSessionID: () -> String
    private let now: () -> Date

    private var sessions: [String: StreamJsonAgentSession] = [:]
    private var metas: [String: ChatSessionMeta] = [:]

    public init(spawner: any StreamingProcessSpawning = LiveStreamingProcess(),
                binaryLocator: any BinaryLocating = SystemBinaryLocator(),
                environment: [String: String],
                makeSessionID: @escaping () -> String = { UUID().uuidString.lowercased() },
                now: @escaping () -> Date = { Date() }) {
        self.spawner = spawner
        self.binaryLocator = binaryLocator
        self.environment = environment
        self.makeSessionID = makeSessionID
        self.now = now
    }

    @discardableResult
    public func create(repoPath: String) async -> ChatSessionMeta {
        let id = makeSessionID()
        let session = StreamJsonAgentSession(sessionID: id, repoPath: repoPath, environment: environment,
                                             spawner: spawner, binaryLocator: binaryLocator)
        sessions[id] = session
        let meta = ChatSessionMeta(id: id, repoPath: repoPath, createdAt: now())
        metas[id] = meta
        await session.start()
        return meta
    }

    public func list() -> [ChatSessionMeta] { Array(metas.values) }

    public func close(id: String) async {
        await sessions[id]?.stop()
        sessions[id] = nil
        metas[id] = nil
    }

    public func send(id: String, text: String) async {
        await sessions[id]?.send(text)
    }

    public func snapshots(id: String) async -> AsyncStream<ChatJournalState>? {
        guard let session = sessions[id] else { return nil }
        return await session.snapshots()
    }
}
