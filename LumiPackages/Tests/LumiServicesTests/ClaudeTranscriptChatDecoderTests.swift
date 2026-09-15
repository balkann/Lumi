import Testing
import Foundation
@testable import LumiServices
import LumiKit

@Suite struct ClaudeTranscriptChatDecoderTests {
    private let decoder = ClaudeTranscriptChatDecoder()

    @Test func decodesUserTextString() {
        let rec: [String: Any] = ["type": "user", "uuid": "u1",
                                  "message": ["content": "merhaba"]]
        let msg = decoder.decode(rec, index: 0)
        #expect(msg?.role == .user)
        #expect(msg?.blocks == [.text("merhaba", presentation: nil)])
        #expect(msg?.id == "u1")
    }

    @Test func decodesAssistantTextAndToolUse() {
        let rec: [String: Any] = [
            "type": "assistant", "uuid": "a1",
            "message": ["content": [
                ["type": "text", "text": "düzeltiyorum"],
                ["type": "tool_use", "id": "tu1", "name": "Edit",
                 "input": ["file_path": "/x/file.swift"]],
            ]],
        ]
        let msg = decoder.decode(rec, index: 1)
        #expect(msg?.role == .assistant)
        #expect(msg?.blocks.count == 2)
        #expect(msg?.blocks[0] == .text("düzeltiyorum", presentation: nil))
        if case let .toolCall(name, preview, _) = msg?.blocks[1] {
            #expect(name == "Edit")
            #expect(preview.contains("file.swift"))
        } else { Issue.record("tool-call bekleniyordu") }
    }

    @Test func decodesToolResult() {
        let rec: [String: Any] = [
            "type": "user", "uuid": "r1",
            "message": ["content": [
                ["type": "tool_result", "tool_use_id": "tu1", "content": "tamam", "is_error": false],
            ]],
        ]
        let msg = decoder.decode(rec, index: 2)
        #expect(msg?.role == .user)
        #expect(msg?.blocks == [.toolResult(output: "tamam", isError: false)])
    }

    @Test func skipsMetaAndUnknown() {
        #expect(decoder.decode(["type": "user", "isMeta": true, "message": ["content": "x"]], index: 0) == nil)
        #expect(decoder.decode(["type": "summary"], index: 0) == nil)
    }
}
