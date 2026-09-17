import Foundation
import LumiKit

/// Bir chat oturumu: claude'u stream-json child olarak çalıştırır, çıktısını
/// journal'a katlar, kullanıcı mesajını stdin'e yazar (spec §D). PTY yok.
public actor StreamJsonAgentSession {
    private let sessionID: String
    private let repoPath: String
    private let environment: [String: String]
    private let spawner: any StreamingProcessSpawning
    private let binaryLocator: any BinaryLocating

    private let journal = ChatJournal()
    private var handle: (any StreamingProcessHandle)?
    private var readTask: Task<Void, Never>?
    private var snapshotContinuations: [AsyncStream<ChatJournalState>.Continuation] = []
    private var finished = false

    public init(sessionID: String, repoPath: String, environment: [String: String],
                spawner: any StreamingProcessSpawning, binaryLocator: any BinaryLocating) {
        self.sessionID = sessionID
        self.repoPath = repoPath
        self.environment = environment
        self.spawner = spawner
        self.binaryLocator = binaryLocator
    }

    public func start() async {
        guard handle == nil else { return }
        let claude = await binaryLocator.locate("claude") ?? "claude"
        let args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--include-partial-messages", "--verbose", "--session-id", sessionID]
        let h = spawner.spawn(executable: claude, arguments: args,
                              currentDirectory: repoPath, environment: environment)
        handle = h
        readTask = Task { [weak self] in
            guard let self else { return }
            for await line in h.lines {
                if Task.isCancelled { break }
                await self.ingest(line)
            }
            await self.finishSnapshots()
        }
    }

    private func ingest(_ line: String) {
        let snap = journal.reduce(StreamJsonEvent.decode(line))
        for c in snapshotContinuations { c.yield(snap) }
    }

    private func finishSnapshots() {
        for c in snapshotContinuations { c.finish() }
        snapshotContinuations.removeAll()
        finished = true
    }

    public func send(_ text: String) async {
        let payload: [String: Any] = ["type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        handle?.write(json + "\n")
    }

    public func snapshots() -> AsyncStream<ChatJournalState> {
        AsyncStream { continuation in
            continuation.yield(journal.state)   // mevcut durum
            if finished {
                continuation.finish()
            } else {
                snapshotContinuations.append(continuation)
            }
        }
    }

    public func stop() async {
        readTask?.cancel()
        handle?.terminate()
        handle = nil
        finishSnapshots()
    }
}
