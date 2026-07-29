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
        if let best = bestCandidate() {
            if best.0 != matchedFile {
                // ilk eşleşme VEYA daha yeni bir oturum dosyasına geçiş
                matchedFile = best.0
                offset = fileSize(best.0)
                pendingPartial = ""
            }
        }
        guard let file = matchedFile else { return }
        readNewLines(from: file)
    }

    private func bestCandidate() -> (URL, Date)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let cutoff = sessionCreatedAt.addingTimeInterval(-120)
        let candidates = entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { return nil }
                return mtime >= cutoff ? (url, mtime) : nil
            }
            .sorted { $0.1 > $1.1 }
        return candidates.first
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    /// Eşleşen jsonl'in kuyruğunu parse edip son `limit` item'ı döner (backfill).
    /// Ayrı handle ile okur; canlı tail durumuna YALNIZCA yayın başladıktan sonra (continuation != nil)
    /// dokunur — erken çağrı yan-etkisiz okur, böylece ilk-poll öncesi offset canlı akışla çiftlenmeye
    /// yol açmaz. Henüz eşleşme yoksa o an eşleştirmeyi dener; yine yoksa [].
    func historyItems(limit: Int = 50, maxTailBytes: Int = 262_144) -> [FeedItem] {
        let file: URL
        if let matched = matchedFile {
            file = matched
        } else if let best = bestCandidate() {
            // Yayın başladıysa ilk-eşleşmeyi kalıcılaştır (poll() ile aynı kurulum);
            // başlamadıysa yan etkisiz oku — erken offset canlı akışla çiftlenme yaratabilir.
            if continuation != nil {
                matchedFile = best.0
                offset = fileSize(best.0)
                pendingPartial = ""
            }
            file = best.0
        } else {
            return []
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        let size = fileSize(file)
        let start = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return [] }

        // Lossy decode: geçersiz UTF-8 baytlar (çok baytlı karakter sınırında kesim dahil)
        // U+FFFD olur; start > 0 ise zaten ilk (yarım) satır aşağıda atılır.
        var chunk = String(decoding: data, as: UTF8.self)

        // Kuyruk ortadan kesildiyse ilk satır yarımdır — at.
        if start > 0, let newline = chunk.firstIndex(of: "\n") {
            chunk = String(chunk[chunk.index(after: newline)...])
        }
        var items: [FeedItem] = []
        for line in chunk.components(separatedBy: "\n") where !line.isEmpty {
            items.append(contentsOf: TranscriptParser.parse(line: line))
        }
        return Array(items.suffix(limit))
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
