import Testing
import Foundation
@testable import LumiRemote
import LumiKit
import LumiTestSupport

@Suite("RemoteCommandHandler")
@MainActor
struct RemoteCommandHandlerTests {

    // MARK: - Terminal start_session (regression)

    @Test func startSessionTerminalSpawnsProcess() async throws {
        let term = FakeTerminalService()
        let trust = FakeClaudeWorkspaceTrust()
        let handler = RemoteCommandHandler(terminal: term, trust: trust)
        let result = await handler.handle([
            "action": "start_session",
            "repoPath": "/repo",
            "prompt": "merhaba",
            "commandId": "cmd-1"
        ])
        #expect(result["ok"] as? Bool == true)
        #expect(term.spawnedMetas.last != nil)
    }

    @Test func startSessionBindsClaudeSessionID() async throws {
        let term = FakeTerminalService()
        let trust = FakeClaudeWorkspaceTrust()
        let handler = RemoteCommandHandler(terminal: term, trust: trust)
        _ = await handler.handle([
            "action": "start_session",
            "repoPath": "/repo",
            "prompt": "merhaba",
            "commandId": "cmd-1"
        ])
        let meta = term.spawnedMetas.last
        #expect(meta != nil)
        #expect(meta?.claudeSessionID != nil)   // chat modu bağlanabilsin
    }

    // MARK: - kind=chat start_session

    @Test func startSessionKindChatCreatesChatSession() async throws {
        let term = FakeTerminalService()
        let trust = FakeClaudeWorkspaceTrust()
        let chatSvc = FakeChatSessionService()
        let meta = ChatSessionMeta(id: "cs-test-1", repoPath: "/repo", createdAt: Date())
        chatSvc.stub(meta: meta, snapshots: [])
        let handler = RemoteCommandHandler(terminal: term, trust: trust, chatSessions: chatSvc)
        let result = await handler.handle([
            "action": "start_session",
            "kind": "chat",
            "repoPath": "/repo",
            "commandId": "cmd-chat-1"
        ])
        #expect(result["ok"] as? Bool == true)
        #expect(result["sessionId"] as? String == "cs-test-1")
        // Terminal spawn OLMAMALIYDI
        #expect(term.spawnedMetas.isEmpty)
        // ChatService create çağrıldı
        #expect(chatSvc.created.count == 1)
    }

    @Test func startSessionKindChatWithPromptSendsText() async throws {
        let term = FakeTerminalService()
        let trust = FakeClaudeWorkspaceTrust()
        let chatSvc = FakeChatSessionService()
        let meta = ChatSessionMeta(id: "cs-test-2", repoPath: "/repo", createdAt: Date())
        chatSvc.stub(meta: meta, snapshots: [])
        let handler = RemoteCommandHandler(terminal: term, trust: trust, chatSessions: chatSvc)
        _ = await handler.handle([
            "action": "start_session",
            "kind": "chat",
            "repoPath": "/repo",
            "prompt": "Merhaba Claude",
            "commandId": "cmd-chat-2"
        ])
        // send çağrıldı
        #expect(chatSvc.sentText.count == 1)
        #expect(chatSvc.sentText.first?.id == "cs-test-2")
        #expect(chatSvc.sentText.first?.text == "Merhaba Claude")
    }

    @Test func startSessionKindChatEmptyPromptDoesNotSend() async throws {
        let term = FakeTerminalService()
        let trust = FakeClaudeWorkspaceTrust()
        let chatSvc = FakeChatSessionService()
        let meta = ChatSessionMeta(id: "cs-test-3", repoPath: "/repo", createdAt: Date())
        chatSvc.stub(meta: meta, snapshots: [])
        let handler = RemoteCommandHandler(terminal: term, trust: trust, chatSessions: chatSvc)
        _ = await handler.handle([
            "action": "start_session",
            "kind": "chat",
            "repoPath": "/repo",
            "commandId": "cmd-chat-3"
        ])
        // prompt yok → send çağrılmadı
        #expect(chatSvc.sentText.isEmpty)
    }

    // MARK: - chat_send (via RemoteService frame router)
    // chat_send, RemoteService.handleInbound'da yönlendirilir; handler doğrudan
    // bu frame'i işlemez. Handler seviyesi için RemoteServiceChatBridgeTests kullanılır.
    // Burada handler'ın chat_send'i bilemediğini (unknown_action döneceğini) doğrular.
    @Test func chatSendIsHandledByRemoteServiceNotHandler() async throws {
        let term = FakeTerminalService()
        let trust = FakeClaudeWorkspaceTrust()
        let handler = RemoteCommandHandler(terminal: term, trust: trust)
        // chat_send bir "action" değil, "type"; handler bunu bilmez.
        let result = await handler.handle([
            "action": "chat_send",
            "sessionId": "some-id",
            "text": "test",
            "commandId": "cmd-chat-send"
        ])
        #expect(result["ok"] as? Bool == false)
        #expect(result["error"] as? String == "unknown_action")
    }
}
