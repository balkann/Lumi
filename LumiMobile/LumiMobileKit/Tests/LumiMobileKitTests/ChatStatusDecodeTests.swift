import XCTest
@testable import LumiMobileKit
import LumiWire

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

    func testDecodeChatStatusStreamingText() {
        // Faz 2: streamingText alanı wire'dan doğru decode edilmeli.
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s1","working":true,"startedAtMs":100,"tool":"Bash","streamingText":"Sel"}}
        """#
        guard case let .chatStatus(sessionId, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status streamingText decode edilemedi")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(status.streamingText, "Sel")
        XCTAssertTrue(status.working)
    }

    func testDecodeChatStatusStreamingTextNil() {
        // streamingText null gelince nil olmalı (geriye-uyum).
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s2","working":true,"startedAtMs":null,"tool":null,"streamingText":null}}
        """#
        guard case let .chatStatus(_, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status streamingText null decode edilemedi")
        }
        XCTAssertNil(status.streamingText)
    }
}
