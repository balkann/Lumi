import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiRemote

@Suite @MainActor struct RemoteServiceChatFallbackTests {
    @Test func chatSubscribeWithoutClaudeSessionDoesNotFallToTerminal() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let hooks = FakeAgentHookServer()
        let uuid = UUID()
        // claudeSessionID YOK (dış/taze oturum) → eski kod PTY'ye düşerdi.
        term.metas.append(TerminalMeta(id: TerminalID(raw: uuid), name: "T",
            repoPath: "/no/transcript/repo", createdAt: Date(), claudeSessionID: nil))
        let sid = TerminalID(raw: uuid).description
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
            connection: conn, chatSource: FakeChatTranscriptSource(events: []), hookEvents: hooks.events())
        await svc.start()
        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
        try await conn.waitForSent(types: ["chat_status"])
        // Ham-PTY yolu ASLA kurulmaz:
        #expect(await conn.sentTypes().contains("scrollback") == false)
        #expect(await conn.sentTypes().contains("data") == false)
        svc.stop()
    }
}
