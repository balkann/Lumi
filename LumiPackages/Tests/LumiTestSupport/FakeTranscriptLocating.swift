import LumiKit

/// Testte sabit bir sessionID döndüren TranscriptLocating fake'i.
public final class FakeTranscriptLocating: TranscriptLocating, @unchecked Sendable {
    private let result: String?

    public init(returning sessionID: String?) {
        self.result = sessionID
    }

    public func locate(repoPath: String) -> String? { result }
}
