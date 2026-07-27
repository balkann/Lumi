import Foundation
import LumiKit

/// Bir terminal oturumunun Claude Code transcript'ini izler (spec §4.2).
/// Dosya sistemi olayı yerine basit polling: 1.5 sn'de bir dizin/dosya kontrolü.
/// Eşleşme: repo cwd'sinin proje dizinindeki, oturum başlangıcından (−120 sn
/// tolerans) yeni, en güncel mtime'lı jsonl. Eşleşemezse akış boş kalır —
/// "yalnız durum modu" (spec §5); her poll'da yeniden denenir.
actor TranscriptWatcher {
    private let projectDir: URL
    private let sessionCreatedAt: Date
    private nonisolated let pollInterval: Duration

    private var matchedFile: URL?
    private var offset: UInt64 = 0
    private var pendingPartial = ""
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<FeedItem>.Continuation?

    init(
        projectsRoot: URL,
        repoPath: String,
        sessionCreatedAt: Date,
        pollInterval: Duration = .milliseconds(1500)
    ) {
        self.projectDir = projectsRoot
            .appendingPathComponent(TranscriptParser.projectDirName(forCwd: repoPath))
        self.sessionCreatedAt = sessionCreatedAt
        self.pollInterval = pollInterval
    }

    func items() -> AsyncStream<FeedItem> {
        let (stream, continuation) = AsyncStream.makeStream(of: FeedItem.self)
        self.continuation = continuation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
        return stream
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func poll() {
        if matchedFile == nil { tryMatch() }
        guard let file = matchedFile else { return }
        readNewLines(from: file)
    }

    private func tryMatch() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = sessionCreatedAt.addingTimeInterval(-120)
        let candidates = entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { return nil }
                return mtime >= cutoff ? (url, mtime) : nil
            }
            .sorted { $0.1 > $1.1 }
        guard let (file, _) = candidates.first else { return }
        matchedFile = file
        // Eşleşme anındaki içerik "geçmiş"tir — yalnız sonrası akar.
        offset = (try? fm.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
    }

    private func readNewLines(from file: URL) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        let chunk = pendingPartial + (String(data: data, encoding: .utf8) ?? "")
        var lines = chunk.components(separatedBy: "\n")
        // Son parça \n ile bitmiyorsa yarım satırdır — bir sonraki poll'a sakla.
        pendingPartial = chunk.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
        for line in lines where !line.isEmpty {
            for item in TranscriptParser.parse(line: line) {
                continuation?.yield(item)
            }
        }
    }
}
