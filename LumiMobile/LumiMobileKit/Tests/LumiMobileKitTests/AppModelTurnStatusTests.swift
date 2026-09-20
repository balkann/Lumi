import XCTest
@testable import LumiMobileKit
import LumiWire

@MainActor
final class AppModelTurnStatusTests: XCTestCase {
    private func makeModel() -> AppModel {
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
        return AppModel(client: FakeRelayClient(), store: store)
    }

    private func meta(_ id: String, repo: String, _ status: String = "idle") -> SessionMeta {
        SessionMeta(id: id, repoName: repo, status: status, title: nil, model: nil, cols: 80, rows: 24)
    }

    func testChatStatusMergesIntoTurnStatus() {
        let model = makeModel()
        model.handle(.chatStatus(sessionId: "s1", status: ChatTurnStatus(working: true, startedAtMs: 10, tool: "Read")))
        XCTAssertEqual(model.turnStatus["s1"], ChatTurnStatus(working: true, startedAtMs: 10, tool: "Read"))
    }

    func testActiveSessionDisappearClearsTurnStatus() {
        let model = makeModel()
        // s1 is the active session + turnStatus is populated.
        model.handle(.sessions([meta("s1", repo: "lumi", "working")]))
        model.subscribe("s1")
        model.handle(.chatStatus(sessionId: "s1", status: ChatTurnStatus(working: true, startedAtMs: 10, tool: "Read")))
        XCTAssertNotNil(model.turnStatus["s1"])
        // When s1 drops from the list (closed/deleted), turnStatus should be cleared.
        model.handle(.sessions([]))
        XCTAssertNil(model.turnStatus["s1"])
    }
}
