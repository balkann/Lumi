import Foundation
import LumiKit

/// repoPath → en yeni Claude transcript sessionID'si. Lumi-dışı (claudeSessionID taşımayan)
/// oturumları chat moduna bağlamak için. fileList enjekte edilir (test + saflık).
public struct TranscriptLocator: TranscriptLocating {
    /// (encoded repo) → o klasördeki [(jsonl adı = sessionID, değişiklik zamanı)].
    private let fileList: @Sendable (String) -> [(sessionID: String, modified: Date)]

    public init(fileList: @escaping @Sendable (String) -> [(sessionID: String, modified: Date)]) {
        self.fileList = fileList
    }

    /// Canlı FS ile üretim başlatıcısı.
    public init() {
        self.fileList = { @Sendable encoded in
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects/\(encoded)")
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys) else { return [] }
            return urls.filter { $0.pathExtension == "jsonl" }.compactMap { url in
                let m = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                return (url.deletingPathExtension().lastPathComponent, m)
            }
        }
    }

    public func locate(repoPath: String) -> String? {
        let encoded = repoPath.replacingOccurrences(
            of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        return fileList(encoded).max(by: { $0.modified < $1.modified })?.sessionID
    }
}
