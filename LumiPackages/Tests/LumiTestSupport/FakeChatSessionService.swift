import Foundation
import LumiKit

/// Test için sahte chat oturumu servisi. `stub(meta:snapshots:)` ile `create`'in
/// döndüreceği meta ve `snapshots(id:)`'in yayacağı journal durumları kurulur;
/// `created`/`sentText` çağrıları biriktirir (RemoteService köprü testleri).
public final class FakeChatSessionService: ChatSessionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _created: [ChatSessionMeta] = []
    private var _sentText: [(id: String, text: String)] = []
    private var stubbedMeta: ChatSessionMeta?
    private var stubbedSnapshots: [ChatJournalState] = []

    public init() {}

    public var created: [ChatSessionMeta] { lock.withLock { _created } }
    public var sentText: [(id: String, text: String)] { lock.withLock { _sentText } }

    /// Test kurulumu: `create`'in döndüreceği meta + `snapshots(id:)`'in sırayla
    /// yayıp bitireceği journal durumları.
    public func stub(meta: ChatSessionMeta, snapshots: [ChatJournalState]) {
        lock.withLock { stubbedMeta = meta; stubbedSnapshots = snapshots }
    }

    @discardableResult
    public func create(repoPath: String) async -> ChatSessionMeta {
        lock.withLock {
            let meta = stubbedMeta
                ?? ChatSessionMeta(id: "fake-session", repoPath: repoPath, createdAt: Date(timeIntervalSince1970: 0))
            _created.append(meta)
            return meta
        }
    }

    public func list() async -> [ChatSessionMeta] { created }

    public func close(id: String) async {}

    public func send(id: String, text: String) async {
        lock.withLock { _sentText.append((id: id, text: text)) }
    }

    public func snapshots(id: String) async -> AsyncStream<ChatJournalState>? {
        let snaps = lock.withLock { stubbedSnapshots }
        return AsyncStream { continuation in
            for state in snaps { continuation.yield(state) }
            continuation.finish()
        }
    }
}
