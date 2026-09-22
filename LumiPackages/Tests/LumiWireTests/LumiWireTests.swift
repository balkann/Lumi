import XCTest
import LumiWire

final class LumiWireTests: XCTestCase {
    func testChatTurnStatusDecode() {
        let d: [String: Any] = ["working": true, "startedAtMs": 12345, "tool": "bash"]
        let status = ChatTurnStatus.decode(d)
        XCTAssertTrue(status.working)
        XCTAssertEqual(status.startedAtMs, 12345)
        XCTAssertEqual(status.tool, "bash")
    }

    func testChatPromptDecode() {
        let d: [String: Any] = [
            "itemId": "x1", "revision": 1, "kind": "approval", "title": "Allow?",
            "state": "pending", "options": [], "multiSelect": false, "allowOther": false,
            "questions": [],
        ]
        let prompt = ChatPrompt.decode(d)
        XCTAssertNotNil(prompt)
        XCTAssertEqual(prompt?.itemId, "x1")
        XCTAssertEqual(prompt?.kind, .approval)
    }

    func testChatMessageDecode() {
        let d: [String: Any] = [
            "id": "m1", "role": "assistant",
            "blocks": [["type": "text", "text": "hello"]],
            "timestamp": 999, "turnId": "t1",
        ]
        let msg = ChatMessage.decode(d)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.id, "m1")
        XCTAssertEqual(msg?.role, .assistant)
        XCTAssertEqual(msg?.blocks, [.text("hello", presentation: nil)])
    }
}
