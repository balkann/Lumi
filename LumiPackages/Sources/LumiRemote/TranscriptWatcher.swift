import Foundation
import LumiKit

/// Bir terminalin Claude Code transcript'ini izler (spec §4.2), DETERMİNİSTİK eşleşme.
/// 1.5 sn polling. Eşleşme (bkz. `resolveMatch`):
/// 1. **Pointer:** SessionStart hook'unun yazdığı `<tid>.json` → `transcript_path`
///    (dosya diskte varsa). /clear/resume/compact/fork ve worktree bununla çözülür.
/// 2. **Fallback (global exactFile):** pointer yoksa (hook henüz tetiklenmedi/kurulu
///    değil), tüm `<projectsRoot>/*/` altında `<tid>.jsonl` ara. id global unique →
///    en çok bir sonuç; worktree'yi hook olmadan da bulur (ilk oturum köprüsü).
/// 3. Aksi halde nil → grace sonrası bir kez `.mirrorUnavailable` yayılır (not-mirrored).
///
/// Aktif dosya değişince (ilk eşleşme sonrası farklı dosya) `.sessionReset` yayılır →
/// RemoteService `transcript_reset` yollar → telefon feed'i temizler.
actor TranscriptWatcher {
    private let projectsRoot: URL
    private let terminalID: String
    private let pointerStore: TranscriptPointerStore
    private nonisolated let pollInterval: Duration
    private let notMirrorableAfterPolls: Int

    private var matchedFile: URL?
    private var offset: UInt64 = 0
    private var pendingPartial = ""
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<FeedItem>.Continuation?
    private var everMatched = false
    private var emptyPolls = 0
    private var emittedUnavailable = false

    init(
        projectsRoot: URL,
        terminalID: String,
        pointerStore: TranscriptPointerStore,
        pollInterval: Duration = .milliseconds(1500),
        notMirrorableAfterPolls: Int = 4
    ) {
        self.projectsRoot = projectsRoot
        self.terminalID = terminalID.lowercased()
        self.pointerStore = pointerStore
        self.pollInterval = pollInterval
        self.notMirrorableAfterPolls = notMirrorableAfterPolls
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
        pollTask?.cancel(); pollTask = nil
        continuation?.finish(); continuation = nil
    }

    private func poll() async {
        let match = resolveMatch()
        if let match {
            emptyPolls = 0
            if match != matchedFile {
                let wasMatched = matchedFile != nil
                matchedFile = match
                // İlk eşleşmede: mevcut içeriği atla (sadece yeni satırları tail'le).
                // Dosya değişiminde (/clear, resume, fork): yeni dosyanın başından oku.
                offset = wasMatched ? 0 : fileSize(match)
                pendingPartial = ""
                if wasMatched {
                    // Aktif dosya değişti (/clear, resume, fork) → reset sinyali.
                    continuation?.yield(.sessionReset)
                }
                everMatched = true
                emittedUnavailable = false
            }
        } else {
            // Eşleşme yok. Fresh oturumda pointer/dosya birkaç poll gecikebilir → grace.
            if matchedFile == nil, !everMatched, !emittedUnavailable {
                emptyPolls += 1
                if emptyPolls >= notMirrorableAfterPolls {
                    emittedUnavailable = true
                    continuation?.yield(.mirrorUnavailable)
                }
            }
            return
        }
        guard let file = matchedFile else { return }
        readNewLines(from: file)
    }

    /// 1) pointer (dosya varsa) → 2) global <tid>.jsonl → nil.
    private func resolveMatch() -> URL? {
        if let p = pointerStore.transcriptPath(for: terminalID),
           FileManager.default.fileExists(atPath: p.path) {
            return p
        }
        return globalExactFile()
    }

    /// Tüm proje dizinlerinde `<tid>.jsonl` ara (id global unique → tek sonuç).
    private func globalExactFile() -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil) else { return nil }
        let name = "\(terminalID).jsonl"
        for dir in dirs {
            let candidate = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    /// Eşleşen jsonl'in kuyruğunu parse edip son `limit` item'ı döner (backfill).
    /// Yayın başladıysa (continuation != nil) ilk eşleşmeyi kalıcılaştırır.
    func historyItems(limit: Int = 50, maxTailBytes: Int = 262_144) async -> [FeedItem] {
        let resolved = resolveMatch()
        rlog("historyItems tid=\(terminalID) matched=\(matchedFile?.lastPathComponent ?? "-") candidate=\(resolved?.lastPathComponent ?? "-")")
        let file: URL
        if let matched = matchedFile, FileManager.default.fileExists(atPath: matched.path) {
            file = matched
        } else if let resolved {
            if continuation != nil {
                matchedFile = resolved
                offset = fileSize(resolved)
                pendingPartial = ""
                everMatched = true
            }
            file = resolved
        } else {
            return []
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = fileSize(file)
        let start = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        var chunk = String(decoding: data, as: UTF8.self)
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
        pendingPartial = chunk.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
        for line in lines where !line.isEmpty {
            for item in TranscriptParser.parse(line: line) {
                continuation?.yield(item)
            }
        }
    }
}
