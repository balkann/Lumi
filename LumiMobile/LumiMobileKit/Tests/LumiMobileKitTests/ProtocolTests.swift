import XCTest
@testable import LumiMobileKit

final class ProtocolTests: XCTestCase {

    // MARK: Gelen mesajlar

    func testDecodeWelcomeWithSnapshot() throws {
        let text = """
        {"v":1,"type":"welcome","payload":{"macOnline":true,"lastSeenAt":1753660000000,
         "snapshot":{"sessions":[{"id":"s1","repoPath":"/r/lumi","repoName":"lumi",
                                  "status":"waiting-unseen","title":"swift test"}],
                     "repos":[{"name":"lumi","path":"/r/lumi"}],
                     "personas":[{"id":"reviewer","label":"Reviewer"}]}}}
        """
        guard case .welcome(let welcome)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("welcome bekleniyordu")
        }
        XCTAssertTrue(welcome.macOnline)
        XCTAssertEqual(welcome.lastSeenAt, 1_753_660_000_000)
        let snapshot = try XCTUnwrap(welcome.snapshot)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].status, .waitingUnseen)
        XCTAssertEqual(snapshot.sessions[0].status.badge, .waiting)
        XCTAssertEqual(snapshot.sessions[0].title, "swift test")
        XCTAssertEqual(snapshot.repos, [Repo(name: "lumi", path: "/r/lumi")])
        XCTAssertEqual(snapshot.personas, [Persona(id: "reviewer", label: "Reviewer")])
    }

    func testDecodeWelcomeMacOffline() {
        let text = #"{"v":1,"type":"welcome","payload":{"snapshot":null,"macOnline":false,"lastSeenAt":null}}"#
        guard case .welcome(let welcome)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("welcome bekleniyordu")
        }
        XCTAssertFalse(welcome.macOnline)
        XCTAssertNil(welcome.snapshot)
        XCTAssertNil(welcome.lastSeenAt)
    }

    func testDecodeStandaloneSnapshot() {
        let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[],"repos":[],"personas":[]}}"#
        guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("snapshot bekleniyordu")
        }
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testDecodeStatusChangeEvent() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"status_change","sessionId":"s1","status":"working","repoName":"lumi","summary":"derliyor"}}"#
        guard case .event(.statusChange(let id, let status, let repo, let summary))? =
                PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("status_change bekleniyordu")
        }
        XCTAssertEqual(id, "s1")
        XCTAssertEqual(status, .working)
        XCTAssertEqual(repo, "lumi")
        XCTAssertEqual(summary, "derliyor")
    }

    func testDecodeTranscriptVariants() {
        let cases: [(String, FeedItem)] = [
            (#"{"itemType":"assistant_text","text":"merhaba"}"#, .assistantText("merhaba")),
            (#"{"itemType":"tool_use","tool":"Bash","summary":"swift test"}"#,
             .toolUse(tool: "Bash", summary: "swift test")),
            (#"{"itemType":"question","questions":[{"header":"İzin","question":"Bash koşsun mu?","options":["Evet","Hayır"]}]}"#,
             .question([Question(header: "İzin", question: "Bash koşsun mu?", options: ["Evet", "Hayır"])])),
            (#"{"itemType":"turn_done"}"#, .turnDone),
        ]
        for (itemJson, expected) in cases {
            let text = #"{"v":1,"type":"event","payload":{"kind":"transcript","sessionId":"s1","item":"# + itemJson + "}}"
            guard case .event(.transcript(let id, let item))? = PhoneProtocol.decodeServerMessage(text) else {
                return XCTFail("transcript bekleniyordu: \(itemJson)")
            }
            XCTAssertEqual(id, "s1")
            XCTAssertEqual(item, expected)
        }
    }

    func testDecodeCommandResult() {
        let text = #"{"v":1,"type":"command_result","payload":{"commandId":"ph-1","ok":false,"error":"mac_offline"}}"#
        guard case .commandResult(let result)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("command_result bekleniyordu")
        }
        XCTAssertEqual(result, CommandResult(commandId: "ph-1", ok: false, error: "mac_offline"))
    }

    // MARK: Tolerans (tasarım §12.2)

    func testUnknownStatusFallsBackToIdle() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"status_change","sessionId":"s1","status":"hibernating","repoName":"r"}}"#
        guard case .event(.statusChange(_, let status, _, _))? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("status_change bekleniyordu")
        }
        XCTAssertEqual(status, .idle)
    }

    func testUnknownItemTypeAndMessageTypeAreSkipped() {
        XCTAssertNil(PhoneProtocol.decodeServerMessage(
            #"{"v":1,"type":"event","payload":{"kind":"transcript","sessionId":"s1","item":{"itemType":"hologram"}}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage(#"{"v":1,"type":"teleport","payload":{}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage(#"{"v":2,"type":"pong","payload":{}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage("bozuk json"))
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
        let sendText = OutgoingCommand(commandId: "ph-1", action: .sendText(sessionId: "s1", text: "devam"))
        var payload = try self.payload(of: PhoneProtocol.commandFrame(sendText), expectedType: "command")
        XCTAssertEqual(payload["commandId"] as? String, "ph-1")
        XCTAssertEqual(payload["action"] as? String, "send_text")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        XCTAssertEqual(payload["text"] as? String, "devam")

        let pressKey = OutgoingCommand(commandId: "ph-2", action: .pressKey(sessionId: "s1", key: "enter"))
        payload = try self.payload(of: PhoneProtocol.commandFrame(pressKey), expectedType: "command")
        XCTAssertEqual(payload["action"] as? String, "press_key")
        XCTAssertEqual(payload["key"] as? String, "enter")

        let start = OutgoingCommand(commandId: "ph-3",
                                    action: .startSession(repoPath: "/r/lumi", personaId: "reviewer", prompt: "testleri koş"))
        payload = try self.payload(of: PhoneProtocol.commandFrame(start), expectedType: "command")
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

    func testDecodeHistoryEvent() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"history","sessionId":"s1","items":[{"itemType":"assistant_text","text":"eski"},{"itemType":"hologram"},{"itemType":"turn_done"}]}}"#
        guard case .event(.history(let id, let items))? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("history bekleniyordu")
        }
        XCTAssertEqual(id, "s1")
        // bilinmeyen itemType atlanır, kalanlar sıralı gelir
        XCTAssertEqual(items, [.assistantText("eski"), .turnDone])
    }

    func testGetHistoryCommandFrame() throws {
        let cmd = OutgoingCommand(commandId: "ph-9", action: .getHistory(sessionId: "s1"))
        let payload = try payload(of: PhoneProtocol.commandFrame(cmd), expectedType: "command")
        XCTAssertEqual(payload["action"] as? String, "get_history")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
    }

    func testEncodeDeleteSessionCommand() throws {
        let frame = PhoneProtocol.commandFrame(
            OutgoingCommand(commandId: "c9", action: .deleteSession(sessionId: "s1")))
        let data = try XCTUnwrap(frame.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["type"] as? String, "command")
        let payload = try XCTUnwrap(dict["payload"] as? [String: Any])
        XCTAssertEqual(payload["action"] as? String, "delete_session")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        XCTAssertEqual(payload["commandId"] as? String, "c9")
    }

    func testDecodeAwaitingDecisionEvent() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"awaiting_decision","sessionId":"s1","awaiting":true}}"#
        guard case .event(.awaitingDecision(let id, let awaiting))? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("awaiting_decision bekleniyordu")
        }
        XCTAssertEqual(id, "s1")
        XCTAssertTrue(awaiting)
    }

    func testDecodeAwaitingDecisionMissingAwaitingDefaultsFalse() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"awaiting_decision","sessionId":"s1"}}"#
        guard case .event(.awaitingDecision(_, let awaiting))? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("awaiting_decision bekleniyordu")
        }
        XCTAssertFalse(awaiting)
    }

    func testDecodeSnapshotSessionAwaitingDecision() {
        let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"waiting-unseen","awaitingDecision":true}],"repos":[],"personas":[]}}"#
        guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("snapshot bekleniyordu")
        }
        XCTAssertTrue(snapshot.sessions[0].awaitingDecision)
    }

    func testDecodeSnapshotSessionAwaitingDefaultsFalseWhenAbsent() {
        let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"idle"}],"repos":[],"personas":[]}}"#
        guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("snapshot bekleniyordu")
        }
        XCTAssertFalse(snapshot.sessions[0].awaitingDecision)
    }

    func testDecodeModelChangeEvent() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"model_change","sessionId":"s1","model":"claude-opus-4-8"}}"#
        guard case .event(.modelChange(let id, let model))? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("model_change bekleniyordu")
        }
        XCTAssertEqual(id, "s1")
        XCTAssertEqual(model, "claude-opus-4-8")
    }

    func testDecodeSnapshotSessionModel() {
        let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"working","model":"claude-sonnet-4-6"}],"repos":[],"personas":[]}}"#
        guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("snapshot bekleniyordu")
        }
        XCTAssertEqual(snapshot.sessions[0].model, "claude-sonnet-4-6")
    }

    func testDecodeSnapshotSessionModelNilWhenAbsent() {
        let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"idle"}],"repos":[],"personas":[]}}"#
        guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("snapshot bekleniyordu")
        }
        XCTAssertNil(snapshot.sessions[0].model)
    }

    func testEncodeSetModelCommand() throws {
        let frame = PhoneProtocol.commandFrame(
            OutgoingCommand(commandId: "m9", action: .setModel(sessionId: "s1", model: "sonnet")))
        let data = try XCTUnwrap(frame.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(dict["payload"] as? [String: Any])
        XCTAssertEqual(payload["action"] as? String, "set_model")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        XCTAssertEqual(payload["model"] as? String, "sonnet")
        XCTAssertEqual(payload["commandId"] as? String, "m9")
    }
}
