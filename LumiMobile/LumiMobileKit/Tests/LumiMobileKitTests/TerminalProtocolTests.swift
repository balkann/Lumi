import Testing
import Foundation
@testable import LumiMobileKit

@Suite struct TerminalProtocolTests {

    // MARK: Decode — data chunk

    @Test func decodesDataChunk() {
        let text = #"{"v":1,"type":"data","payload":{"sessionId":"s1","seq":2,"data":"aGk="}}"#
        guard case .data(let chunk)? = PhoneProtocol.decodeServerMessage(text) else {
            Issue.record("wrong"); return
        }
        #expect(chunk.sessionId == "s1")
        #expect(chunk.seq == 2)
        #expect(chunk.bytes == "hi".data(using: .utf8))
    }

    @Test func decodesDataChunkColsRowsAbsent() {
        let text = #"{"v":1,"type":"data","payload":{"sessionId":"s1","seq":5,"data":"aGk="}}"#
        guard case .data(let chunk)? = PhoneProtocol.decodeServerMessage(text) else {
            Issue.record("data chunk expected"); return
        }
        #expect(chunk.cols == nil)
        #expect(chunk.rows == nil)
    }

    // MARK: Decode — scrollback chunk

    @Test func decodesScrollbackWithColsRows() {
        let text = #"{"v":1,"type":"scrollback","payload":{"sessionId":"s2","seq":1,"cols":80,"rows":24,"data":"aGVsbG8="}}"#
        guard case .scrollback(let chunk)? = PhoneProtocol.decodeServerMessage(text) else {
            Issue.record("scrollback expected"); return
        }
        #expect(chunk.sessionId == "s2")
        #expect(chunk.seq == 1)
        #expect(chunk.cols == 80)
        #expect(chunk.rows == 24)
        #expect(chunk.bytes == "hello".data(using: .utf8))
    }

    // MARK: Decode — sessions message

    @Test func decodesSessionsMessage() {
        let text = #"{"v":1,"type":"sessions","payload":{"sessions":[{"id":"s1","repoName":"lumi","status":"working","cols":200,"rows":50}]}}"#
        guard case .sessions(let list)? = PhoneProtocol.decodeServerMessage(text) else {
            Issue.record("sessions expected"); return
        }
        #expect(list.count == 1)
        #expect(list[0].id == "s1")
        #expect(list[0].repoName == "lumi")
        #expect(list[0].status == "working")
        #expect(list[0].cols == 200)
        #expect(list[0].rows == 50)
        #expect(list[0].title == nil)
        #expect(list[0].model == nil)
    }

    @Test func decodesSessionsMessageWithOptionalFields() {
        let text = #"{"v":1,"type":"sessions","payload":{"sessions":[{"id":"s2","repoName":"repo","status":"idle","cols":80,"rows":24,"title":"My Task","model":"claude-sonnet-4-6"}]}}"#
        guard case .sessions(let list)? = PhoneProtocol.decodeServerMessage(text) else {
            Issue.record("sessions expected"); return
        }
        #expect(list[0].title == "My Task")
        #expect(list[0].model == "claude-sonnet-4-6")
    }

    // MARK: Decode — welcome with sessions

    @Test func decodesWelcomeWithSessions() {
        let text = #"{"v":1,"type":"welcome","payload":{"macOnline":true,"sessions":[{"id":"s1","repoName":"lumi","status":"idle","cols":80,"rows":24}]}}"#
        guard case .welcome(let welcome)? = PhoneProtocol.decodeServerMessage(text) else {
            Issue.record("welcome expected"); return
        }
        #expect(welcome.macOnline == true)
        let sessionsMeta = welcome.sessions
        #expect(sessionsMeta != nil)
        #expect(sessionsMeta?.count == 1)
        #expect(sessionsMeta?[0].id == "s1")
    }

    @Test func decodesWelcomeSessionsNilWhenAbsent() {
        let text = #"{"v":1,"type":"welcome","payload":{"macOnline":false,"snapshot":null,"lastSeenAt":null}}"#
        guard case .welcome(let welcome)? = PhoneProtocol.decodeServerMessage(text) else {
            Issue.record("welcome expected"); return
        }
        #expect(welcome.sessions == nil)
    }

    // MARK: Encode — subscribe / unsubscribe / input

    @Test func encodesSubscribeFrame() {
        let frame = PhoneProtocol.subscribeFrame(sessionId: "s1")
        #expect(frame.contains(#""type":"subscribe""#))
        #expect(frame.contains(#""sessionId":"s1""#))
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["v"] as? Int == 1)
        #expect(obj["type"] as? String == "subscribe")
        let payload = obj["payload"] as? [String: Any]
        #expect(payload?["sessionId"] as? String == "s1")
    }

    @Test func encodesUnsubscribeFrame() {
        let frame = PhoneProtocol.unsubscribeFrame(sessionId: "s1")
        #expect(frame.contains(#""type":"unsubscribe""#))
        #expect(frame.contains(#""sessionId":"s1""#))
    }

    @Test func encodesInputFrameBase64() {
        let frame = PhoneProtocol.inputFrame(sessionId: "s1", data: "hi".data(using: .utf8)!)
        #expect(frame.contains(#""type":"input""#))
        #expect(frame.contains(#""aGk=""#))
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = obj["payload"] as? [String: Any]
        #expect(payload?["sessionId"] as? String == "s1")
        #expect(payload?["data"] as? String == "aGk=")
    }

    @Test func inputFrameEncodesArbitraryBytes() {
        let bytes = Data([0x00, 0x01, 0x02, 0xFF])
        let frame = PhoneProtocol.inputFrame(sessionId: "sess", data: bytes)
        let d = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: d) as! [String: Any]
        let payload = obj["payload"] as? [String: Any]
        let b64 = payload?["data"] as? String
        #expect(Data(base64Encoded: b64!) == bytes)
    }

    // MARK: Tolerance — malformed payloads return nil

    @Test func malformedDataChunkReturnsNil() {
        // missing required sessionId
        let text = #"{"v":1,"type":"data","payload":{"seq":1,"data":"aGk="}}"#
        #expect(PhoneProtocol.decodeServerMessage(text) == nil)
    }
}
