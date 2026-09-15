import XCTest
@testable import LumiMobileKit

final class ChatStatusDecodeTests: XCTestCase {
    func testDecodeChatStatusFrame() {
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s1","working":true,"startedAtMs":42,"tool":"Bash"}}
        """#
        guard case let .chatStatus(sessionId, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status decode edilemedi")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(status, ChatTurnStatus(working: true, startedAtMs: 42, tool: "Bash"))
    }

    func testDecodeChatStatusIdleWithNulls() {
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s1","working":false,"startedAtMs":null,"tool":null}}
        """#
        guard case let .chatStatus(_, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status idle decode edilemedi")
        }
        XCTAssertEqual(status, .idle)
    }
}
