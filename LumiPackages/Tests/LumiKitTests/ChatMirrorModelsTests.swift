import Testing
import Foundation
@testable import LumiKit

@Suite struct ChatMirrorModelsTests {
    @Test func textMessageToDict() {
        let msg = ChatMessage(
            id: "m1", role: .assistant,
            blocks: [.text("hi", presentation: nil)],
            timestampMs: 1000, turnId: "t1"
        )
        let d = msg.toDict()
        #expect(d["id"] as? String == "m1")
        #expect(d["role"] as? String == "assistant")
        #expect(d["timestamp"] as? Int == 1000)
        #expect(d["turnId"] as? String == "t1")
        let blocks = d["blocks"] as? [[String: Any]]
        #expect(blocks?.first?["type"] as? String == "text")
        #expect(blocks?.first?["text"] as? String == "hi")
    }

    @Test func toolBlocksToDict() {
        let msg = ChatMessage(
            id: "m2", role: .assistant,
            blocks: [
                .toolCall(name: "Edit", inputPreview: "file.swift", state: "completed"),
                .toolResult(output: "ok", isError: false),
            ],
            timestampMs: nil, turnId: nil
        )
        let d = msg.toDict()
        #expect(d["timestamp"] is NSNull)
        let blocks = d["blocks"] as? [[String: Any]]
        #expect(blocks?[0]["type"] as? String == "tool-call")
        #expect(blocks?[0]["name"] as? String == "Edit")
        #expect(blocks?[0]["inputPreview"] as? String == "file.swift")
        #expect(blocks?[1]["type"] as? String == "tool-result")
        #expect(blocks?[1]["output"] as? String == "ok")
    }

    @Test func subagentGroupToDict() {
        let block = ChatBlock.subagentGroup(groupId: "g1", agents: [
            ChatSubagentEntry(id: "c1", label: "child", state: "working", tokens: 42),
        ])
        let d = block.toDict()
        #expect(d["type"] as? String == "subagent-group")
        #expect(d["groupId"] as? String == "g1")
        let agents = d["agents"] as? [[String: Any]]
        #expect(agents?.first?["id"] as? String == "c1")
        #expect(agents?.first?["tokens"] as? Int == 42)
    }
}
