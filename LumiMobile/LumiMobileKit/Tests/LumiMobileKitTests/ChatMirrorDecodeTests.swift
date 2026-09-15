import XCTest
@testable import LumiMobileKit

final class ChatMirrorDecodeTests: XCTestCase {
    func testDecodeChatFrame() {
        let frame = #"""
        {"v":1,"type":"chat","payload":{"sessionId":"s1","messages":[
          {"id":"m1","role":"user","timestamp":5,"blocks":[{"type":"text","text":"hi"}]},
          {"id":"m2","role":"assistant","timestamp":null,"blocks":[
            {"type":"tool-call","name":"Edit","inputPreview":"file.swift"},
            {"type":"tool-result","output":"ok","isError":false}]}]}}
        """#
        guard case let .chat(sessionId, messages)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat decode edilemedi")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].blocks, [.text("hi", presentation: nil)])
        XCTAssertEqual(messages[1].blocks.first, .toolCall(name: "Edit", inputPreview: "file.swift", state: nil))
    }

    func testDecodeChatAppendFrame() {
        let frame = #"{"v":1,"type":"chat_append","payload":{"sessionId":"s1","messages":[{"id":"m3","role":"assistant","blocks":[{"type":"text","text":"done"}]}]}}"#
        guard case let .chatAppend(_, messages)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_append decode edilemedi")
        }
        XCTAssertEqual(messages.first?.id, "m3")
    }

    func testSubscribeFrameCarriesMode() {
        let frame = PhoneProtocol.subscribeFrame(sessionId: "s1", mode: "chat")
        XCTAssertTrue(frame.contains("\"mode\":\"chat\""))
    }
}
