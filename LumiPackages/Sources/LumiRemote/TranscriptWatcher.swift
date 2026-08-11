import Foundation
import LumiKit

/// Bir terminal oturumunun Claude Code transcript'ini izler (spec §4.2).
/// Dosya sistemi olayı yerine basit polling: 1.5 sn'de bir dizin/dosya kontrolü.
///
/// Eşleşme öncelik sırası (bkz. `resolveMatch`):
/// 1. **Kesin (session-id):** `sessionId` verildiyse (Lumi'nin başlattığı claude
///    oturumu, bkz. `ClaudeSessionID`) ve `<sessionId>.jsonl` diskte varsa KESİN
///    o dosya — deterministik, çoklu-oturumda yanlış/eski eşleşmeyi önler.
/// 2. **Çoklu-oturum (owner+registry):** kesin dosya yoksa, aynı repoda eş zamanlı
///    tab'ları `TranscriptClaimRegistry` birthtime≈createdAt ile tekil sahiplikle
///    ayırır (session-id'siz komutlar — codex/bash/eski oturumlar — için crosstalk'ı
///    engeller; mtime sezgiseli tek başına mesajları tab'lar arası sızdırır).
/// 3. **Tek-oturum sezgiseli:** kardeş yoksa/standalone — proje dizininde önce oturum
///    başlangıcından (−120 sn tolerans) yeni, en güncel mtime'lı jsonl; öyle biri
///    yoksa dizindeki en yeni jsonl'e düşülür (restart'ta `sessionCreatedAt`
///    sıfırlandığında oturum-öncesi transcript'in kaybolmaması için).
///
/// Eşleşen jsonl yoksa akış boş kalır — "yalnız durum modu" (spec §5); her poll'da
/// yeniden denenir.
actor TranscriptWatcher {
    private let projectDir: URL
    private let sessionCreatedAt: Date
    private let exactFile: URL?
    private nonisolated let pollInterval: Duration
    /// Aynı repoda eş zamanlı terminalleri ayırt etmek için tekil-sahiplik
    /// koordinatörü + bu terminalin kimliği. İkisi de verildiğinde çoklu-oturum
    /// modu; nil ise (standalone/test) tek-oturum mtime sezgiseli kullanılır.
    private let owner: TerminalID?
    private let registry: TranscriptClaimRegistry?

    private var matchedFile: URL?
    private var offset: UInt64 = 0
    private var pendingPartial = ""
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<FeedItem>.Continuation?
    /// Başı `/clear` olduğu doğrulanmış dosya yolları (pozitif önbellek; bir dosya
    /// bir kez /clear-ardılı olarak görüldüyse öyle kalır).
    private var clearSuccessorCache: Set<String> = []
    /// Oturum-dosyası değişiminde yeni dosyanın komple akıtılmasını önlemek için
    /// replay tavanı (son ~256KB; historyItems backfill sınırıyla aynı).
    private static let switchReplayCap: UInt64 = 262_144

    init(
        projectsRoot: URL,
        repoPath: String,
        sessionCreatedAt: Date,
        sessionId: String? = nil,
        pollInterval: Duration = .milliseconds(1500),
        owner: TerminalID? = nil,
        registry: TranscriptClaimRegistry? = nil
    ) {
        let dir = projectsRoot
            .appendingPathComponent(TranscriptParser.projectDirName(forCwd: repoPath))
        self.projectDir = dir
        self.sessionCreatedAt = sessionCreatedAt
        self.exactFile = sessionId.map { dir.appendingPathComponent("\($0).jsonl") }
        self.pollInterval = pollInterval
        self.owner = owner
        self.registry = registry
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

    private func poll() async {
        if let match = await resolveMatch(), match != matchedFile {
            // ilk eşleşme (matchedFile==nil) → yalnız kuyruğu tail'le; canlı öncesi
            // içerik get_history ile gelir. Oturum DEĞİŞİMİ (matchedFile!=nil, ör.
            // /clear yeni dosya açtı) → telefon feed'ini sıfırla ve yeni dosyanın son
            // ~256KB'ını baştan oynat (aksi halde /clear ile poll arasında yazılan ilk
            // prompt/yanıt kaybolurdu).
            let isSwitch = matchedFile != nil
            matchedFile = match
            offset = isSwitch ? replayStart(match) : fileSize(match)
            pendingPartial = ""
            if isSwitch { continuation?.yield(.sessionReset) }
        }
        guard let file = matchedFile else { return }
        readNewLines(from: file)
    }

    /// Oturum değişiminde yeni dosyanın SON `switchReplayCap` baytını baştan
    /// oynatmak için başlangıç offset'i. Ortadan kesilen ilk yarım satır JSON-parse
    /// edilemez → TranscriptParser onu sessizce düşer (veri kaybı yok).
    private func replayStart(_ url: URL) -> UInt64 {
        let size = fileSize(url)
        return size > Self.switchReplayCap ? size - Self.switchReplayCap : 0
    }

    /// exactFile'dan sonra doğmuş (mtime), başı `<command-name>/clear</command-name>`
    /// olan EN YENİ jsonl. `/clear` yeni oturum dosyası açtığında watcher'ın ona
    /// ilerlemesini sağlar; normal (daha-yeni ama /clear olmayan) kardeş dosyalara
    /// DOKUNMAZ — o crosstalk olurdu (bkz. exact-wins testi, crosstalk fix kararı).
    private func clearSuccessor(newerThan base: URL) -> URL? {
        let baseMtime = (try? base.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        for (url, m) in sortedByMtime() where url != base && m > baseMtime {
            if isClearSuccessor(url) { return url }  // sortedByMtime azalan → ilk = en yeni
        }
        return nil
    }

    /// Dosyanın başı bir `/clear` komut kaydı içeriyor mu (yalnız head okunur).
    private func isClearSuccessor(_ url: URL) -> Bool {
        if clearSuccessorCache.contains(url.path) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 32_768)) ?? Data()
        let isSuccessor = String(decoding: head, as: UTF8.self)
            .contains("<command-name>/clear</command-name>")
        if isSuccessor { clearSuccessorCache.insert(url.path) }  // yalnız pozitifi önbelleğe al
        return isSuccessor
    }

    /// Bu terminalin bağlanacağı jsonl (öncelik sırası tip yorumunda):
    /// 1. `exactFile` (session-id) diskte varsa — kesin, deterministik.
    /// 2. Çoklu-oturum tekil-sahiplik (owner+registry) — kardeş tab ayrımı.
    /// 3. Tek-oturum mtime sezgiseli (+ restart fallback).
    private func resolveMatch() async -> URL? {
        if let exactFile, FileManager.default.fileExists(atPath: exactFile.path) {
            // /clear exactFile'ı bayatlatıp yeni <uuid>.jsonl açar → ardıla ilerle.
            if let successor = clearSuccessor(newerThan: exactFile) { return successor }
            return exactFile
        }
        if let owner, let registry {
            switch await registry.assignment(for: owner) {
            case .file(let url): return url
            case .unassigned: return nil
            case .solo: break  // tek terminal → aşağıdaki sezgisele düş
            }
        }
        return heuristicMatch()
    }

    /// Tek-oturum sezgiseli: proje dizininde önce oturum başlangıcından (−120 sn
    /// tolerans) yeni, en güncel mtime'lı jsonl; öyle biri yoksa dizindeki en yeni
    /// jsonl'e düşülür (restart'ta `sessionCreatedAt` sıfırlandığında oturum-öncesi
    /// transcript'in kaybolmaması için).
    private func heuristicMatch() -> URL? {
        let cutoff = sessionCreatedAt.addingTimeInterval(-120)
        let candidates = sortedByMtime()
        return (candidates.first { $0.1 >= cutoff } ?? candidates.first)?.0
    }

    private func sortedByMtime() -> [(URL, Date)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { return nil }
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    /// Eşleşen jsonl'in kuyruğunu parse edip son `limit` item'ı döner (backfill).
    /// Ayrı handle ile okur; canlı tail durumuna YALNIZCA yayın başladıktan sonra (continuation != nil)
    /// dokunur — erken çağrı yan-etkisiz okur, böylece ilk-poll öncesi offset canlı akışla çiftlenmeye
    /// yol açmaz. Henüz eşleşme yoksa o an eşleştirmeyi dener; yine yoksa [].
    func historyItems(limit: Int = 50, maxTailBytes: Int = 262_144) async -> [FeedItem] {
        let resolved = await resolveMatch()
        rlog("historyItems projectDir=\(projectDir.path) exists=\(FileManager.default.fileExists(atPath: projectDir.path)) matched=\(matchedFile?.lastPathComponent ?? "-") candidate=\(resolved?.lastPathComponent ?? "-")")
        let file: URL
        if let resolved {
            // resolveMatch() clear-aware: exactFile ya da /clear-ardılı (bayat matchedFile'ı
            // bile ezer). Yayın başladıysa canlı tail'i de bu dosyaya kilitle; başlamadıysa
            // yan etkisiz oku (erken offset canlı akışla çiftlenme yaratabilir).
            if continuation != nil, resolved != matchedFile {
                matchedFile = resolved
                offset = fileSize(resolved)
                pendingPartial = ""
            }
            file = resolved
        } else if let matched = matchedFile {
            file = matched
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
