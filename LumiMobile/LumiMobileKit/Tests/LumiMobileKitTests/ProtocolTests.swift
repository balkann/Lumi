import XCTest
@testable import LumiMobileKit

final class ProtocolTests: XCTestCase {

    // MARK: Gelen mesajlar

    func testDecodeWelcomeMacOffline() {
        let text = #"{"v":1,"type":"welcome","payload":{"macOnline":false,"lastSeenAt":null}}"#
        guard case .welcome(let welcome)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("welcome bekleniyordu")
        }
        XCTAssertFalse(welcome.macOnline)
        XCTAssertNil(welcome.sessions)
        XCTAssertNil(welcome.lastSeenAt)
    }

    func testDecodeCommandResult() {
        let text = #"{"v":1,"type":"command_result","payload":{"commandId":"ph-1","ok":false,"error":"mac_offline"}}"#
        guard case .commandResult(let result)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("command_result bekleniyordu")
        }
        XCTAssertEqual(result, CommandResult(commandId: "ph-1", ok: false, error: "mac_offline"))
    }

    func testDecodePong() {
        guard case .pong? = PhoneProtocol.decodeServerMessage(#"{"v":1,"type":"pong","payload":{}}"#) else {
            return XCTFail("pong bekleniyordu")
        }
    }

    // MARK: Tolerans (tasarım §12.2)

    func testUnknownMessageTypesAreSkipped() {
        XCTAssertNil(PhoneProtocol.decodeServerMessage(#"{"v":1,"type":"teleport","payload":{}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage(#"{"v":2,"type":"pong","payload":{}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage("bozuk json"))
        // Kaldırılan chat tipleri artık tanınmamalı
        XCTAssertNil(PhoneProtocol.decodeServerMessage(#"{"v":1,"type":"snapshot","payload":{"sessions":[],"repos":[],"personas":[]}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage(#"{"v":1,"type":"event","payload":{"kind":"transcript","sessionId":"s1","item":{"itemType":"turn_done"}}}"#))
    }

    // MARK: Giden mesajlar

    private func payload(of frame: String, expectedType: String) throws -> [String: Any] {
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(frame.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(dict["v"] as? Int, 1)
        XCTAssertEqual(dict["type"] as? String, expectedType)
        return try XCTUnwrap(dict["payload"] as? [String: Any])
    }

    func testHelloFrame() throws {
        let payload = try payload(of: PhoneProtocol.helloFrame(token: "0123456789abcdef"), expectedType: "hello")
        XCTAssertEqual(payload["role"] as? String, "phone")
        XCTAssertEqual(payload["token"] as? String, "0123456789abcdef")
    }

    func testCommandFrames() throws {
        let start = OutgoingCommand(commandId: "ph-3",
                                    action: .startSession(repoPath: "/r/lumi", personaId: "reviewer", prompt: "testleri koş"))
        var payload = try self.payload(of: PhoneProtocol.commandFrame(start), expectedType: "command")
        XCTAssertEqual(payload["action"] as? String, "start_session")
        XCTAssertEqual(payload["repoPath"] as? String, "/r/lumi")
        XCTAssertEqual(payload["personaId"] as? String, "reviewer")
        XCTAssertEqual(payload["prompt"] as? String, "testleri koş")

        let startNoPersona = OutgoingCommand(commandId: "ph-4",
                                             action: .startSession(repoPath: "/r/lumi", personaId: nil, prompt: "p"))
        payload = try self.payload(of: PhoneProtocol.commandFrame(startNoPersona), expectedType: "command")
        XCTAssertNil(payload["personaId"])
    }

    func testRegisterPushAndPingFrames() throws {
        let push = try payload(of: PhoneProtocol.registerPushFrame(deviceToken: "abc123"), expectedType: "register_push")
        XCTAssertEqual(push["deviceToken"] as? String, "abc123")
        let ping = try payload(of: PhoneProtocol.pingFrame(), expectedType: "ping")
        XCTAssertTrue(ping.isEmpty)
    }

    func testUnregisterPushFrame() {
        let frame = PhoneProtocol.unregisterPushFrame(deviceToken: "abc123")
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["type"] as? String, "unregister_push")
        XCTAssertEqual((obj["payload"] as? [String: Any])?["deviceToken"] as? String, "abc123")
    }

    func testEncodeDeleteSessionCommand() throws {
        let frame = PhoneProtocol.commandFrame(
            OutgoingCommand(commandId: "c9", action: .deleteSession(sessionId: "s1")))
        let payload = try payload(of: frame, expectedType: "command")
        XCTAssertEqual(payload["action"] as? String, "delete_session")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        XCTAssertEqual(payload["commandId"] as? String, "c9")
    }

    func testEncodeSetModelCommand() throws {
        let frame = PhoneProtocol.commandFrame(
            OutgoingCommand(commandId: "m9", action: .setModel(sessionId: "s1", model: "sonnet")))
        let payload = try payload(of: frame, expectedType: "command")
        XCTAssertEqual(payload["action"] as? String, "set_model")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        XCTAssertEqual(payload["model"] as? String, "sonnet")
        XCTAssertEqual(payload["commandId"] as? String, "m9")
    }
}
