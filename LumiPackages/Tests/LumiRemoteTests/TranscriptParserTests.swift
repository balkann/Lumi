import Foundation
import XCTest
@testable import LumiRemote

final class TranscriptParserTests: XCTestCase {
    func testProjectDirNameEncoding() {
        XCTAssertEqual(TranscriptParser.projectDirName(forCwd: "/Users/balkan/Lumi"),
                       "-Users-balkan-Lumi")
        XCTAssertEqual(TranscriptParser.projectDirName(forCwd: "/Users/balkan/wkspaces/sand_out"),
                       "-Users-balkan-wkspaces-sand-out")
        XCTAssertEqual(TranscriptParser.projectDirName(forCwd: "/Users/b/.unco-runner/x+y"),
                       "-Users-b--unco-runner-x-y")
        XCTAssertEqual(TranscriptParser.projectDirName(forCwd: "/Users/b/Proje-Ağ"),
                       "-Users-b-Proje-A-", "ASCII dışı harfler de - olmalı")
    }

    func testAssistantTextParsed() {
        let line = #"{"type":"assistant","uuid":"u1","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Şimdi derliyorum."}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [.assistantText("Şimdi derliyorum.")])
    }

    func testToolUseSummarized() {
        let line = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test","description":"Run tests"}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [.toolUse(name: "Bash", summary: "Run tests")])
    }

    func testToolUseSummaryFallsBackToPathThenCommand() {
        let edit = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"/a/b/Config.swift"}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: edit), [.toolUse(name: "Edit", summary: "Config.swift")])
        let bash = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls -la"}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: bash), [.toolUse(name: "Bash", summary: "ls -la")])
        let bare = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Read","input":{}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: bare), [.toolUse(name: "Read", summary: "")])
    }

    func testAskUserQuestionBecomesQuestion() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"AskUserQuestion","input":{"questions":[{"header":"Ağ","question":"Nereden erişim?","multiSelect":false,"options":[{"label":"Tailscale"},{"label":"Relay"}]}]}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [
            .question(payload: [Question(header: "Ağ", question: "Nereden erişim?", options: ["Tailscale", "Relay"])])
        ])
    }

    func testEndTurnAppendsTurnDone() {
        let line = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Bitti."}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [.assistantText("Bitti."), .turnDone])
    }

    func testIrrelevantAndBrokenLinesYieldNothing() {
        XCTAssertEqual(TranscriptParser.parse(line: #"{"type":"user","message":{"role":"user","content":"selam"}}"#), [])
        XCTAssertEqual(TranscriptParser.parse(line: #"{"type":"system","subtype":"turn_duration"}"#), [])
        XCTAssertEqual(TranscriptParser.parse(line: #"{"type":"ai-title","aiTitle":"x"}"#), [])
        XCTAssertEqual(TranscriptParser.parse(line: "yarım json {"), [])
        XCTAssertEqual(TranscriptParser.parse(line: ""), [])
    }

    func testThinkingBlocksSkipped() {
        let line = #"{"type":"assistant","message":{"stop_reason":null,"content":[{"type":"thinking","thinking":"gizli akıl yürütme"}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [])
    }

    func testEventPayloadShape() throws {
        let item = FeedItem.toolUse(name: "Bash", summary: "swift test")
        let payload = item.eventPayload(sessionId: "s1")
        XCTAssertEqual(payload["kind"] as? String, "transcript")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        let inner = try XCTUnwrap(payload["item"] as? [String: Any])
        XCTAssertEqual(inner["itemType"] as? String, "tool_use")
        XCTAssertEqual(inner["tool"] as? String, "Bash")
        XCTAssertEqual(inner["summary"] as? String, "swift test")
    }

    func testParseExtractsModelFromAssistant() {
        let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"hi"}]}}"#
        let items = TranscriptParser.parse(line: line)
        XCTAssertTrue(items.contains(.model("claude-opus-4-8")), "model çıkarılmalı")
        XCTAssertTrue(items.contains(.assistantText("hi")))
    }

    func testParseNoModelWhenAbsent() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#
        let items = TranscriptParser.parse(line: line)
        XCTAssertFalse(items.contains { if case .model = $0 { return true }; return false })
    }
}
