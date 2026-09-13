import Testing
import Foundation
@testable import LumiRemote

@Suite struct TerminalWireTests {
    @Test func decodeInputBase64() {
        let p: [String: Any] = ["sessionId": "s1", "data": "aGk="]   // "hi"
        let out = RemoteProtocol.decodeInput(p)
        #expect(out?.0 == "s1")
        #expect(out?.1 == "hi".data(using: .utf8))
    }
    @Test func dataPayloadEncodesBase64() {
        let p = RemoteProtocol.dataPayload(sessionId: "s1", seq: 3, data: "hi".data(using: .utf8)!)
        #expect(p["data"] as? String == "aGk=")
        #expect(p["seq"] as? Int == 3)
    }
    @Test func sessionsPayloadKey() {
        let meta = SessionMeta(id: "s1", repoName: "repo", status: "idle", title: nil, model: nil, cols: 80, rows: 24)
        let p = RemoteProtocol.sessionsPayload([meta])
        let arr = p["sessions"] as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?.first?["id"] as? String == "s1")
    }
    @Test func scrollbackPayloadEncodesBase64() {
        let p = RemoteProtocol.scrollbackPayload(sessionId: "s2", seq: 7, cols: 120, rows: 30, data: "hello".data(using: .utf8)!)
        #expect(p["sessionId"] as? String == "s2")
        #expect(p["seq"] as? Int == 7)
        #expect(p["cols"] as? Int == 120)
        #expect(p["rows"] as? Int == 30)
        #expect(p["data"] as? String == "hello".data(using: .utf8)!.base64EncodedString())
    }
    @Test func decodeSubscribe() {
        let p: [String: Any] = ["sessionId": "s3"]
        #expect(RemoteProtocol.decodeSubscribe(p) == "s3")
    }
    @Test func decodeSubscribeMissing() {
        let p: [String: Any] = [:]
        #expect(RemoteProtocol.decodeSubscribe(p) == nil)
    }
    @Test func sessionMetaOmitsNilFields() {
        let meta = SessionMeta(id: "x", repoName: "r", status: "running", title: nil, model: nil, cols: 80, rows: 24)
        let dict = meta.toDict()
        #expect(dict["title"] == nil)
        #expect(dict["model"] == nil)
        #expect(dict["id"] as? String == "x")
    }
    @Test func sessionMetaIncludesOptionalFields() {
        let meta = SessionMeta(id: "x", repoName: "r", status: "running", title: "T", model: "claude-3", cols: 80, rows: 24)
        let dict = meta.toDict()
        #expect(dict["title"] as? String == "T")
        #expect(dict["model"] as? String == "claude-3")
    }
}
