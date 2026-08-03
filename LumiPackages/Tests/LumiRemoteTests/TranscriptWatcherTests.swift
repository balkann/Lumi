import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

final class TranscriptWatcherTests: XCTestCase {
    private var root: URL!
    private var projectDir: URL!
    private let repoPath = "/tmp/demo-repo"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcripts-\(UUID().uuidString)")
        projectDir = root.appendingPathComponent(TranscriptParser.projectDirName(forCwd: repoPath))
        try! FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func assistantLine(_ text: String) -> String {
        #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
    }

    func testTailsOnlyNewLinesAppendedAfterMatch() async throws {
        let file = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try assistantLine("eski").write(to: file, atomically: true, encoding: .utf8)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date().addingTimeInterval(-60),
            pollInterval: .milliseconds(50))
        let stream = await watcher.items()

        // Eşleşme gerçekleşsin diye kısa bekleme, sonra yeni satır ekle
        try await Task.sleep(for: .milliseconds(150))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: assistantLine("yeni").data(using: .utf8)!)
        try handle.close()

        var received: [FeedItem] = []
        for await item in stream {
            received.append(item)
            break
        }
        await watcher.stop()
        XCTAssertEqual(received, [.assistantText("yeni")], "eşleşme öncesi satırlar akmamalı")
    }

    func testIgnoresFilesOlderThanSession() async throws {
        let old = projectDir.appendingPathComponent("old.jsonl")
        try assistantLine("bayat").write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeIntervalDouble(-3600)], ofItemAtPath: old.path)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date(),  // dosyadan çok sonra
            pollInterval: .milliseconds(50))
        let stream = await watcher.items()

        try await Task.sleep(for: .milliseconds(150))
        // Yeni bir dosya oluşunca eşleşmeli
        let fresh = projectDir.appendingPathComponent("fresh.jsonl")
        try Data().write(to: fresh)
        try await Task.sleep(for: .milliseconds(150))
        let handle = try FileHandle(forWritingTo: fresh)
        try handle.write(contentsOf: assistantLine("taze").data(using: .utf8)!)
        try handle.close()

        var received: [FeedItem] = []
        for await item in stream {
            received.append(item)
            break
        }
        await watcher.stop()
        XCTAssertEqual(received, [.assistantText("taze")])
    }

    func testPartialLineWaitsForCompletion() async throws {
        let file = projectDir.appendingPathComponent("s.jsonl")
        try Data().write(to: file)
        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date().addingTimeInterval(-60),
            pollInterval: .milliseconds(50))
        let stream = await watcher.items()
        try await Task.sleep(for: .milliseconds(150))

        let full = assistantLine("tam")
        let half = String(full.prefix(20))
        let rest = String(full.dropFirst(20))
        var handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: half.data(using: .utf8)!)
        try handle.close()
        try await Task.sleep(for: .milliseconds(150))
        handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: rest.data(using: .utf8)!)
        try handle.close()

        var received: [FeedItem] = []
        for await item in stream {
            received.append(item)
            break
        }
        await watcher.stop()
        XCTAssertEqual(received, [.assistantText("tam")])
    }

    func testSwitchesToNewerSessionFile() async throws {
        // Dosya A ile başla, eşleşsin
        let fileA = projectDir.appendingPathComponent("session-a.jsonl")
        try assistantLine("eski-A").write(to: fileA, atomically: true, encoding: .utf8)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date().addingTimeInterval(-60),
            pollInterval: .milliseconds(50))
        let stream = await watcher.items()

        // A'nın eşleşmesi için bekle
        try await Task.sleep(for: .milliseconds(150))

        // Dosya B'yi A'dan kesinlikle daha yeni bir mtime ile oluştur
        let fileB = projectDir.appendingPathComponent("session-b.jsonl")
        try Data().write(to: fileB)
        let mtimeA = (try? fileA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let mtimeB = mtimeA.addingTimeInterval(1)
        try FileManager.default.setAttributes([.modificationDate: mtimeB], ofItemAtPath: fileB.path)

        // B'ye yeni satır yaz
        try await Task.sleep(for: .milliseconds(100))
        let handle = try FileHandle(forWritingTo: fileB)
        try handle.seekToEnd()
        try handle.write(contentsOf: assistantLine("yeni-B").data(using: .utf8)!)
        try handle.close()
        // B'nin mtime'ını güncelle (write sonrası)
        try FileManager.default.setAttributes([.modificationDate: mtimeB.addingTimeInterval(0.1)], ofItemAtPath: fileB.path)

        var received: [FeedItem] = []
        for await item in stream {
            received.append(item)
            break
        }
        await watcher.stop()
        XCTAssertEqual(received, [.assistantText("yeni-B")], "daha yeni dosyaya geçiş yapmalı ve yeni satırları akıtmalı")
    }

    /// Aynı repoda eş zamanlı iki terminal (2 tab): her watcher ortak bir
    /// `TranscriptClaimRegistry` üzerinden KENDİ jsonl'ine (birthtime≈createdAt)
    /// bağlanmalı; birinin satırı diğerinin akışına SIZMAMALI (asıl bug).
    func testConcurrentSessionsBindToOwnFileByBirthtime() async throws {
        let registry = TranscriptClaimRegistry()
        let now = Date()
        let createdA = now.addingTimeInterval(-30)   // önce açılan tab
        let createdB = now.addingTimeInterval(-20)   // 10 sn sonra açılan tab
        let ownerA = TerminalID()
        let ownerB = TerminalID()

        // Her tab'ın kendi jsonl'i, terminalinden ~1 sn sonra doğmuş (birthtime).
        let fileA = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        let fileB = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data().write(to: fileA)   // fileA önce → daha eski mtime
        try Data().write(to: fileB)   // fileB sonra → daha yeni mtime (sezgisel bunu seçerdi)
        try FileManager.default.setAttributes(
            [.creationDate: createdA.addingTimeInterval(1)], ofItemAtPath: fileA.path)
        try FileManager.default.setAttributes(
            [.creationDate: createdB.addingTimeInterval(1)], ofItemAtPath: fileB.path)

        await registry.register(owner: ownerA, dir: projectDir, createdAt: createdA)
        await registry.register(owner: ownerB, dir: projectDir, createdAt: createdB)

        let watcherA = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath, sessionCreatedAt: createdA,
            pollInterval: .milliseconds(50), owner: ownerA, registry: registry)
        let watcherB = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath, sessionCreatedAt: createdB,
            pollInterval: .milliseconds(50), owner: ownerB, registry: registry)
        let streamA = await watcherA.items()
        let streamB = await watcherB.items()

        try await Task.sleep(for: .milliseconds(150))  // eşleşme otursun

        // Her dosyaya kendi mesajını yaz (fileB'yi sonra → en yeni mtime).
        let ha = try FileHandle(forWritingTo: fileA); try ha.seekToEnd()
        try ha.write(contentsOf: assistantLine("mesaj-A").data(using: .utf8)!); try ha.close()
        let hb = try FileHandle(forWritingTo: fileB); try hb.seekToEnd()
        try hb.write(contentsOf: assistantLine("mesaj-B").data(using: .utf8)!); try hb.close()

        var a: FeedItem?
        for await item in streamA { a = item; break }
        var b: FeedItem?
        for await item in streamB { b = item; break }
        await watcherA.stop(); await watcherB.stop()

        XCTAssertEqual(a, .assistantText("mesaj-A"), "A yalnız kendi dosyasını okumalı")
        XCTAssertEqual(b, .assistantText("mesaj-B"), "B yalnız kendi dosyasını okumalı")
    }

    /// Gerçek senaryonun özü (unco-forge'da 49 jsonl): eski oturum dosyaları
    /// SON yazılmış (yeni mtime) olsa bile, birthtime'ları güncel terminallerin
    /// createdAt'inden çok eski olduğu için hiçbir tab'a atanmamalı. Çoklu-oturum
    /// modu mtime yerine birthtime kullandığından her tab yalnız kendi taze
    /// dosyasını okur.
    func testConcurrentSessionsIgnoreOldSessionFilesDespiteNewerMtime() async throws {
        let registry = TranscriptClaimRegistry()
        let now = Date()
        let createdA = now.addingTimeInterval(-20)
        let createdB = now.addingTimeInterval(-10)
        let ownerA = TerminalID()
        let ownerB = TerminalID()

        // Eski oturum dosyaları: birthtime 1 saat önce, ama mtime "şimdi" (write).
        for i in 0..<3 {
            let old = projectDir.appendingPathComponent("old-\(i).jsonl")
            try assistantLine("eski-\(i)").write(to: old, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.creationDate: now.addingTimeInterval(-3600)], ofItemAtPath: old.path)
        }
        // Her tab'ın taze dosyası (birthtime ≈ createdAt).
        let fileA = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        let fileB = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data().write(to: fileA)
        try Data().write(to: fileB)
        try FileManager.default.setAttributes(
            [.creationDate: createdA.addingTimeInterval(1)], ofItemAtPath: fileA.path)
        try FileManager.default.setAttributes(
            [.creationDate: createdB.addingTimeInterval(1)], ofItemAtPath: fileB.path)

        await registry.register(owner: ownerA, dir: projectDir, createdAt: createdA)
        await registry.register(owner: ownerB, dir: projectDir, createdAt: createdB)

        let watcherA = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath, sessionCreatedAt: createdA,
            pollInterval: .milliseconds(50), owner: ownerA, registry: registry)
        let watcherB = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath, sessionCreatedAt: createdB,
            pollInterval: .milliseconds(50), owner: ownerB, registry: registry)
        let streamA = await watcherA.items()
        let streamB = await watcherB.items()

        try await Task.sleep(for: .milliseconds(150))

        let ha = try FileHandle(forWritingTo: fileA); try ha.seekToEnd()
        try ha.write(contentsOf: assistantLine("mesaj-A").data(using: .utf8)!); try ha.close()
        let hb = try FileHandle(forWritingTo: fileB); try hb.seekToEnd()
        try hb.write(contentsOf: assistantLine("mesaj-B").data(using: .utf8)!); try hb.close()

        var a: FeedItem?
        for await item in streamA { a = item; break }
        var b: FeedItem?
        for await item in streamB { b = item; break }
        await watcherA.stop(); await watcherB.stop()

        XCTAssertEqual(a, .assistantText("mesaj-A"), "eski dosyalar (yeni mtime) atanmamalı; A kendi taze dosyasını okumalı")
        XCTAssertEqual(b, .assistantText("mesaj-B"), "B kendi taze dosyasını okumalı")
    }

    func testStopFinishesStream() async throws {
        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date(), pollInterval: .milliseconds(50))
        let stream = await watcher.items()
        await watcher.stop()
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0, "stop() akışı sonlandırmalı")
    }

    // MARK: - sessionId ile kesin eşleşme (fix-transcript-match)

    func testExactSessionIdFileWinsOverNewerHeuristic() async throws {
        let sid = "abcdef01-1111-4222-8333-abcdef012345"
        // Doğru oturumun dosyası: <sid>.jsonl
        let exact = projectDir.appendingPathComponent("\(sid).jsonl")
        try assistantLine("dogru-oturum").write(to: exact, atomically: true, encoding: .utf8)
        // Daha YENİ mtime'lı başka bir oturum dosyası — heuristik bunu seçerdi
        let other = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try assistantLine("yanlis-yeni-oturum").write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: other.path)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date().addingTimeInterval(-60),
            sessionId: sid)
        let items = await watcher.historyItems()
        XCTAssertEqual(items, [.assistantText("dogru-oturum")],
                       "sessionId verildiğinde tam <sid>.jsonl eşlenmeli, daha yeni başka dosya değil")
    }

    func testFallsBackToHeuristicWhenExactFileAbsent() async throws {
        let sid = "11111111-1111-4111-8111-111111111111"
        // <sid>.jsonl YOK; yalnız bir heuristik dosya var
        let other = projectDir.appendingPathComponent("only.jsonl")
        try assistantLine("heuristik").write(to: other, atomically: true, encoding: .utf8)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date().addingTimeInterval(-60),
            sessionId: sid)
        let items = await watcher.historyItems()
        XCTAssertEqual(items, [.assistantText("heuristik")],
                       "exact dosya yoksa heuristik eşleşmeye düşmeli")
    }

    // MARK: - historyItems (Plan 3.5 backfill)

    private func makeHistoryDir() throws -> (root: URL, projectDir: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent(
            TranscriptParser.projectDirName(forCwd: "/tmp/demo"))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        return (root, projectDir)
    }

    private func writeLines(_ lines: [String], to dir: URL, name: String = "s1.jsonl") throws {
        let text = lines.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)!.write(to: dir.appendingPathComponent(name))
    }

    private let assistantLineTpl =
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"MSG"}]}}"#

    func testHistoryItemsReturnsParsedTail() async throws {
        let (root, projectDir) = try makeHistoryDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...5).map { assistantLineTpl.replacingOccurrences(of: "MSG", with: "m\($0)") }
        try writeLines(lines, to: projectDir)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date().addingTimeInterval(-60))
        let items = await watcher.historyItems(limit: 3, maxTailBytes: 262_144)

        XCTAssertEqual(items, [
            .assistantText("m3"), .assistantText("m4"), .assistantText("m5"),
        ])
    }

    func testHistoryItemsDropsPartialFirstLineWhenTailCut() async throws {
        let (root, projectDir) = try makeHistoryDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...4).map { assistantLineTpl.replacingOccurrences(of: "MSG", with: "m\($0)") }
        try writeLines(lines, to: projectDir)
        // maxTailBytes'ı 2. satırın ortasına denk gelecek kadar küçült:
        // son 3 satır + 2. satırın kuyruğu okunur; yarım satır atılmalı.
        let lineBytes = (lines[0] + "\n").utf8.count
        let tail = lineBytes * 2 + lineBytes / 2

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date().addingTimeInterval(-60))
        let items = await watcher.historyItems(limit: 50, maxTailBytes: tail)

        XCTAssertEqual(items, [.assistantText("m3"), .assistantText("m4")])
    }

    /// Restart senaryosu: Lumi yeniden başlayınca terminaller sıfırdan yaratılır ve
    /// `sessionCreatedAt` "şimdi"ye sıfırlanır; oturum-öncesi transcript ise cutoff'tan
    /// (createdAt−120s) eskidir. Cutoff'u geçen jsonl yoksa dizindeki EN YENİ jsonl'e
    /// düşülmeli — aksi halde telefon oturumu açınca backfill boş gelir (bug).
    func testHistoryItemsFallsBackToNewestWhenAllOlderThanSession() async throws {
        let (root, projectDir) = try makeHistoryDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...3).map { assistantLineTpl.replacingOccurrences(of: "MSG", with: "m\($0)") }
        try writeLines(lines, to: projectDir, name: "old-session.jsonl")
        let old = projectDir.appendingPathComponent("old-session.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date())  // transcript'ten çok sonra (restart)
        let items = await watcher.historyItems(limit: 50, maxTailBytes: 262_144)

        XCTAssertEqual(items, [.assistantText("m1"), .assistantText("m2"), .assistantText("m3")],
                       "cutoff'u geçen jsonl yoksa en yeni jsonl'e düşülmeli (restart backfill)")
    }

    func testHistoryItemsEmptyWhenNoMatch() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-none-\(UUID().uuidString)")
        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date())
        let items = await watcher.historyItems(limit: 50, maxTailBytes: 262_144)
        XCTAssertTrue(items.isEmpty)
    }

    /// historyItems(), items() çağrılmadan (yayın başlamadan) önce çağrıldığında:
    /// - geçmiş item'larını döner (yan-etkisiz okuma),
    /// - sonraki items() çağrısı ve yeni satır append'i canlı teslimata yol açar
    ///   (erken historyItems çağrısı offset'i kilitleyip çiftlenme/kaçırma yaratmaz).
    func testHistoryItemsBeforeStreamDoesNotBreakLiveDelivery() async throws {
        let (root, projectDir) = try makeHistoryDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = projectDir.appendingPathComponent("s-live.jsonl")
        let existingLine = assistantLineTpl.replacingOccurrences(of: "MSG", with: "gecmis")
        try (existingLine + "\n").data(using: .utf8)!.write(to: file)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date().addingTimeInterval(-60),
            pollInterval: .milliseconds(50))

        // Yayın BAŞLAMADAN historyItems çağrılır (yan-etkisiz olmalı)
        let history = await watcher.historyItems(limit: 50, maxTailBytes: 262_144)
        XCTAssertEqual(history, [.assistantText("gecmis")], "geçmiş item'ları dönmeli")

        // Şimdi yayını başlat
        let stream = await watcher.items()

        // Watcher'ın dosyayı eşleştirmesi için kısa bekleme
        try await Task.sleep(for: .milliseconds(150))

        // Yeni satır ekle
        let newLine = assistantLineTpl.replacingOccurrences(of: "MSG", with: "canli")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: (newLine + "\n").data(using: .utf8)!)
        try handle.close()

        // Canlı satır stream'den gelmeli (erken historyItems çağrısı bunu engellememiş olmalı)
        var received: [FeedItem] = []
        for await item in stream {
            received.append(item)
            break
        }
        await watcher.stop()
        XCTAssertEqual(received, [.assistantText("canli")],
                       "erken historyItems çağrısı canlı teslimi bozmamalı")
    }

    func testItemPayloadShapes() {
        XCTAssertEqual(
            FeedItem.assistantText("hi").itemPayload["itemType"] as? String, "assistant_text")
        let tool = FeedItem.toolUse(name: "Bash", summary: "swift test").itemPayload
        XCTAssertEqual(tool["tool"] as? String, "Bash")
        XCTAssertEqual(tool["summary"] as? String, "swift test")
        // eventPayload sarmalaması aynı kalmalı (mevcut telefonlar kırılmasın)
        let wrapped = FeedItem.turnDone.eventPayload(sessionId: "s1")
        XCTAssertEqual(wrapped["kind"] as? String, "transcript")
        XCTAssertEqual(wrapped["sessionId"] as? String, "s1")
        XCTAssertEqual((wrapped["item"] as? [String: Any])?["itemType"] as? String, "turn_done")
    }

    /// Çok baytlı UTF-8 karakter sınırına denk gelen tail kesiminin sessiz veri
    /// kaybına ([] dönüşüne) yol açmadığını doğrular.
    func testHistoryItemsUtf8BoundaryDoesNotDropAllLines() async throws {
        let (root, projectDir) = try makeHistoryDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // "ş" karakteri 2 bayttır; her satır aynı uzunluktadır.
        let multibyteText = String(repeating: "ş", count: 10)   // 20 bayt
        let lines = (1...3).map { i in
            assistantLineTpl.replacingOccurrences(of: "MSG", with: "\(multibyteText)-\(i)")
        }
        try writeLines(lines, to: projectDir, name: "utf8-test.jsonl")

        // İlk satırın son "ş"nin ikinci baytının (0x9F) ORTASINA düşecek şekilde maxTailBytes hesapla:
        // start = firstLineBytes - 9, yani son "ş"nin 0x9F baytına denk gelen geçersiz bir kesim.
        let firstLineBytes = (lines[0] + "\n").utf8.count
        let totalBytes = lines.reduce(0) { $0 + ($1 + "\n").utf8.count }
        // start = totalBytes - maxTailBytes => firstLineBytes - 9 bayt içinde olsun
        let maxTailBytes = totalBytes - firstLineBytes + 9

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date().addingTimeInterval(-60))
        let items = await watcher.historyItems(limit: 50, maxTailBytes: maxTailBytes)

        // İlk (kesik) satır atılmalı; geri kalan 2 tam satır dönmeli — [] olmamalı.
        XCTAssertEqual(items.count, 2, "UTF-8 sınır kesimi tüm geçmişi silmemeli")
        XCTAssertEqual(items[0], .assistantText("\(multibyteText)-2"))
        XCTAssertEqual(items[1], .assistantText("\(multibyteText)-3"))
    }
}

private extension Date {
    func addingTimeIntervalDouble(_ t: Double) -> Date { addingTimeInterval(t) }
}
