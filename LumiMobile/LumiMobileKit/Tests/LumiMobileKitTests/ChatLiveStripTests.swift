import XCTest
@testable import LumiMobileKit
import LumiWire

@MainActor
final class ChatLiveStripTests: XCTestCase {
    private func makeModel() -> (AppModel, FakeRelayClient) {
        let client = FakeRelayClient()
        // FakeRelayClient + InMemorySecureStore mevcut test yardımcılarıdır (AppModelTests.swift).
        return (AppModel(client: client, store: InMemorySecureStore()), client)
    }

    func testStripVisibilityRule() {
        // (working || pendingPrompt) && hasFeed
        XCTAssertFalse(chatLiveStripVisible(working: false, hasPendingPrompt: false, hasFeed: true))
        XCTAssertTrue(chatLiveStripVisible(working: true, hasPendingPrompt: false, hasFeed: true))
        XCTAssertTrue(chatLiveStripVisible(working: false, hasPendingPrompt: true, hasFeed: true))
        XCTAssertFalse(chatLiveStripVisible(working: true, hasPendingPrompt: true, hasFeed: false))
        XCTAssertFalse(chatLiveStripVisible(working: false, hasPendingPrompt: false, hasFeed: false))
    }

    func testSubscribeChatRoutesFeedToTerminalStream() async {
        let (model, _) = makeModel()
        model.subscribeChat("s1")
        // View (şerit) mount olmadan scrollback geldi → replay tamponuna girmeli.
        model.handle(.scrollback(TerminalChunk(sessionId: "s1", seq: 0, cols: 80, rows: 40,
                                               bytes: Data("hi".utf8))))
        var got: [TerminalChunk] = []
        for await chunk in model.terminalStream("s1") { got.append(chunk); break }
        XCTAssertEqual(got.first?.bytes, Data("hi".utf8))
    }

    func testHasFeedAndGridRows() {
        let (model, _) = makeModel()
        model.subscribeChat("s1")
        XCTAssertFalse(model.hasFeed("s1"))                 // dış oturum: feed yok
        model.handle(.scrollback(TerminalChunk(sessionId: "s1", seq: 0, cols: 80, rows: 40,
                                               bytes: Data())))
        XCTAssertTrue(model.hasFeed("s1"))
        XCTAssertEqual(model.gridRows["s1"], 40)
        // rows'suz data chunk'ı grid'i değiştirmez.
        model.handle(.data(TerminalChunk(sessionId: "s1", seq: 1, bytes: Data("x".utf8))))
        XCTAssertEqual(model.gridRows["s1"], 40)
    }

    func testSubscribeChatCleansPreviousSessionFeed() async {
        let (model, _) = makeModel()
        model.subscribeChat("s1")
        model.handle(.scrollback(TerminalChunk(sessionId: "s1", seq: 0, cols: 80, rows: 24,
                                               bytes: Data("a".utf8))))
        model.subscribeChat("s2")
        // feedSeen KASITLI olarak subscribeChat'ta temizlenmez (oturumun PTY'li
        // olduğu gerçeği oturum değişince değişmez); temizlik applySessions'ta.
        XCTAssertTrue(model.hasFeed("s1"))
        // s1 replay tamponu boşaltıldı; s2 için taze tampon var.
        model.handle(.data(TerminalChunk(sessionId: "s2", seq: 0, bytes: Data("b".utf8))))
        var got: [TerminalChunk] = []
        for await chunk in model.terminalStream("s2") { got.append(chunk); break }
        XCTAssertEqual(got.first?.bytes, Data("b".utf8))
    }
}
