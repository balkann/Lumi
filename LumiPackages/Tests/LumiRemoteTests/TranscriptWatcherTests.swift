import Foundation
import XCTest
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

    func testHistoryItemsEmptyWhenNoMatch() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-none-\(UUID().uuidString)")
        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date())
        let items = await watcher.historyItems(limit: 50, maxTailBytes: 262_144)
        XCTAssertTrue(items.isEmpty)
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
