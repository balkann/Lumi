// LumiPackages/Tests/LumiServicesTests/TranscriptChatSourceTests.swift
import Testing
import Foundation
@testable import LumiServices
import LumiKit

@Suite struct TranscriptChatSourceTests {
    /// Geçici home + claude projects/<encoded>/<sid>.jsonl kur.
    private func makeTranscript(sid: String, repoPath: String, lines: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-chat-\(UUID().uuidString)")
        let encoded = repoPath.replacingOccurrences(of: "/", with: "-")
        let dir = home.appendingPathComponent(".claude/projects/\(encoded)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sid).jsonl")
        try lines.joined(separator: "\n").appending("\n").data(using: .utf8)!.write(to: file)
        return home
    }

    @Test func snapshotThenAppend() async throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let repo = "/Users/x/proj"
        let line1 = #"{"type":"user","uuid":"u1","message":{"content":"selam"}}"#
        let home = try makeTranscript(sid: sid, repoPath: repo, lines: [line1])
        let file = home.appendingPathComponent(
            ".claude/projects/\(repo.replacingOccurrences(of: "/", with: "-"))/\(sid).jsonl")

        let source = TranscriptChatSource(home: home, pollInterval: .milliseconds(20))
        var iterator = source.stream(sessionID: sid, repoPath: repo).makeAsyncIterator()

        let first = await iterator.next()
        guard case let .snapshot(msgs)? = first else { Issue.record("snapshot bekleniyordu"); return }
        #expect(msgs.map(\.id) == ["u1"])

        // Dosyaya yeni satır ekle → append gelmeli.
        let line2 = #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"tamam"}]}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: (line2 + "\n").data(using: .utf8)!)
        try handle.close()

        let second = await iterator.next()
        guard case let .append(more)? = second else { Issue.record("append bekleniyordu"); return }
        #expect(more.map(\.id) == ["a1"])
    }

    @Test func missingFileEmitsEmptySnapshotThenFills() async throws {
        let sid = "22222222-2222-2222-2222-222222222222"
        let repo = "/Users/x/empty"
        // Dosya yok; source boş snapshot verip dosya belirince append etmeli.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-chat-\(UUID().uuidString)")
        let source = TranscriptChatSource(home: home, pollInterval: .milliseconds(20))
        var it = source.stream(sessionID: sid, repoPath: repo).makeAsyncIterator()
        guard case let .snapshot(msgs)? = await it.next() else { Issue.record("snapshot"); return }
        #expect(msgs.isEmpty)
    }
}
