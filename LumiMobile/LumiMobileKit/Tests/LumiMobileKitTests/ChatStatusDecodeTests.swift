import XCTest
@testable import LumiMobileKit
import LumiWire

final class ChatStatusDecodeTests: XCTestCase {
    func testDecodeChatStatusFrame() {
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s1","working":true,"startedAtMs":42,"tool":"Bash"}}
        """#
        guard case let .chatStatus(sessionId, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status could not be decoded")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(status, ChatTurnStatus(working: true, startedAtMs: 42, tool: "Bash"))
    }

    func testDecodeChatStatusIdleWithNulls() {
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s1","working":false,"startedAtMs":null,"tool":null}}
        """#
        guard case let .chatStatus(_, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status idle could not be decoded")
        }
        XCTAssertEqual(status, .idle)
    }

    func testDecodeChatStatusStreamingText() {
        // Phase 2: streamingText field must be correctly decoded from the wire.
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s1","working":true,"startedAtMs":100,"tool":"Bash","streamingText":"Sel"}}
        """#
        guard case let .chatStatus(sessionId, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status streamingText could not be decoded")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(status.streamingText, "Sel")
        XCTAssertTrue(status.working)
    }

    func testDecodeChatStatusStreamingTextNil() {
        // streamingText arriving as null must become nil (backward compatibility).
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s2","working":true,"startedAtMs":null,"tool":null,"streamingText":null}}
        """#
        guard case let .chatStatus(_, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status streamingText null could not be decoded")
        }
        XCTAssertNil(status.streamingText)
    }
}
