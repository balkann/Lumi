import Testing
import Foundation
@testable import LumiRemote
import LumiKit
import LumiTestSupport

@Suite("RemoteCommandHandler")
@MainActor
struct RemoteCommandHandlerTests {

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
}
