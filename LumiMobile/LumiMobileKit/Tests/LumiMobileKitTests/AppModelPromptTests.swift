import XCTest
@testable import LumiMobileKit

@MainActor
final class AppModelPromptTests: XCTestCase {
    private func makeModel() -> AppModel {
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
        return AppModel(client: FakeRelayClient(), store: store)
    }

    private func prompt(_ id: String, state: ChatPromptState) -> ChatPrompt {
        ChatPrompt(itemId: id, revision: 0, kind: .approval, title: "t", detail: nil,
                   options: [ChatPromptOption(id: "allow", label: "Allow", description: nil)],
                   state: state, selectedOptionId: nil)
    }

    func testPendingPromptAddedResolvedRemoved() {
        let m = makeModel()
        m.handle(.prompt(sessionId: "s1", prompt: prompt("i1", state: .pending)))
        XCTAssertEqual(m.prompts["s1"]?.count, 1)
        m.handle(.prompt(sessionId: "s1", prompt: prompt("i1", state: .resolved)))
        XCTAssertTrue((m.prompts["s1"] ?? []).isEmpty)   // resolved → düşer
    }

    func testCancelledPromptRemoved() {
        let m = makeModel()
        m.handle(.prompt(sessionId: "s1", prompt: prompt("i1", state: .pending)))
        m.handle(.prompt(sessionId: "s1", prompt: prompt("i1", state: .cancelled)))
        XCTAssertTrue((m.prompts["s1"] ?? []).isEmpty)
    }

    func testPendingPromptUpdatedInPlace() {
        let m = makeModel()
        m.handle(.prompt(sessionId: "s1", prompt: prompt("i1", state: .pending)))
        m.handle(.prompt(sessionId: "s1", prompt: ChatPrompt(
            itemId: "i1", revision: 1, kind: .approval, title: "t2", detail: nil,
            options: [], state: .pending, selectedOptionId: nil)))
        XCTAssertEqual(m.prompts["s1"]?.count, 1)   // dedup by itemId
        XCTAssertEqual(m.prompts["s1"]?.first?.revision, 1)
    }

    func testDeadActiveSessionClearsPrompts() {
        let m = makeModel()
        m.handle(.prompt(sessionId: "s1", prompt: prompt("i1", state: .pending)))
        m.subscribeChat("s1")   // aktif oturum = s1
        m.handle(.sessions([]))  // s1 artık canlı değil
        XCTAssertNil(m.prompts["s1"])
    }
}
