import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

final class TranscriptWatcherTests: XCTestCase {
    private var root: URL!          // ~/.claude/projects karşılığı
    private var mapDir: URL!        // ~/.lumi/transcript-map karşılığı
    private let tid = "abcdef01-1111-4222-8333-abcdef012345"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("proj-\(UUID().uuidString)")
        mapDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("map-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: mapDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: mapDir)
        super.tearDown()
    }

    private func assistantLine(_ t: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(t)"}]}}"# + "\n"
    }
    private func projDir(_ repo: String) -> URL {
        let d = root.appendingPathComponent(TranscriptParser.projectDirName(forCwd: repo))
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func writePointer(transcriptPath: String) throws {
        let json = #"{"session_id":"\#(tid)","transcript_path":"\#(transcriptPath)","source":"startup"}"#
        try json.data(using: .utf8)!.write(to: mapDir.appendingPathComponent("\(tid).json"))
    }
    private func makeWatcher(pollMs: Int = 50, grace: Int = 4) -> TranscriptWatcher {
        TranscriptWatcher(projectsRoot: root, terminalID: tid,
                          pointerStore: TranscriptPointerStore(mapDir: mapDir),
                          pollInterval: .milliseconds(pollMs), notMirrorableAfterPolls: grace)
    }

    func testTailsFileFromPointer() async throws {
        let dir = projDir("/tmp/demo")
        let file = dir.appendingPathComponent("\(tid).jsonl")
        try assistantLine("eski").write(to: file, atomically: true, encoding: .utf8)
        try writePointer(transcriptPath: file.path)

        let watcher = makeWatcher()
        let stream = await watcher.items()
        try await Task.sleep(for: .milliseconds(150))
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd()
        try h.write(contentsOf: assistantLine("yeni").data(using: .utf8)!); try h.close()

        var got: FeedItem?
        for await item in stream where item != .mirrorUnavailable { got = item; break }
        await watcher.stop()
        XCTAssertEqual(got, .assistantText("yeni"))
    }

    func testFallsBackToGlobalExactFileInWorktreeDir() async throws {
        // Pointer YOK; <tid>.jsonl repo-kökü DEĞİL worktree-türevi dizinde.
        let wtDir = projDir("/tmp/demo/.claude/worktrees/feat-x")
        let file = wtDir.appendingPathComponent("\(tid).jsonl")
        try assistantLine("wt").write(to: file, atomically: true, encoding: .utf8)

        let watcher = makeWatcher()
        let items = await watcher.historyItems()
        await watcher.stop()
        XCTAssertEqual(items, [.assistantText("wt")], "global <tid>.jsonl araması worktree'yi bulmalı")
    }

    func testEmitsSessionResetWhenPointerSwitchesFile() async throws {
        let dir = projDir("/tmp/demo")
        let a = dir.appendingPathComponent("\(tid).jsonl")
        try assistantLine("a").write(to: a, atomically: true, encoding: .utf8)
        try writePointer(transcriptPath: a.path)

        let watcher = makeWatcher()
        let stream = await watcher.items()
        try await Task.sleep(for: .milliseconds(150))

        // /clear: yeni dosya + pointer güncellenir
        let b = dir.appendingPathComponent("newsession.jsonl")
        try assistantLine("b").write(to: b, atomically: true, encoding: .utf8)
        try writePointer(transcriptPath: b.path)

        var sawReset = false
        var sawB = false
        for await item in stream {
            if item == .sessionReset { sawReset = true }
            if item == .assistantText("b") { sawB = true }
            if sawReset && sawB { break }
        }
        await watcher.stop()
        XCTAssertTrue(sawReset, "dosya değişince sessionReset yayılmalı")
        XCTAssertTrue(sawB, "yeni dosyanın satırları akmalı")
    }

    func testEmitsMirrorUnavailableWhenNoFileAfterGrace() async throws {
        // Pointer yok, <tid>.jsonl hiçbir yerde yok.
        let watcher = makeWatcher(pollMs: 20, grace: 2)
        let stream = await watcher.items()
        var got: FeedItem?
        for await item in stream { got = item; break }
        await watcher.stop()
        XCTAssertEqual(got, .mirrorUnavailable)
    }

    func testStopFinishesStream() async throws {
        let watcher = makeWatcher()
        let stream = await watcher.items()
        await watcher.stop()
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testHistoryItemsReturnsParsedTailFromPointer() async throws {
        let dir = projDir("/tmp/demo")
        let file = dir.appendingPathComponent("\(tid).jsonl")
        let lines = (1...5).map { assistantLine("m\($0)") }.joined()
        try lines.write(to: file, atomically: true, encoding: .utf8)
        try writePointer(transcriptPath: file.path)

        let watcher = makeWatcher()
        let items = await watcher.historyItems(limit: 3, maxTailBytes: 262_144)
        await watcher.stop()
        XCTAssertEqual(items, [.assistantText("m3"), .assistantText("m4"), .assistantText("m5")])
    }

    func testHistoryItemsEmptyWhenNoMatch() async {
        let watcher = makeWatcher()
        let items = await watcher.historyItems()
        await watcher.stop()
        XCTAssertTrue(items.isEmpty)
    }
}
