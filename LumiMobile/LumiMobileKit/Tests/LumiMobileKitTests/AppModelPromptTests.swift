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
}
