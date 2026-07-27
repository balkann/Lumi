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
}

private extension Date {
    func addingTimeIntervalDouble(_ t: Double) -> Date { addingTimeInterval(t) }
}
