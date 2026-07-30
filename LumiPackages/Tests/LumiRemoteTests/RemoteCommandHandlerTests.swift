import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

@MainActor
private final class FakeTerminal: TerminalServicing {
    var writes: [(TerminalID, String)] = []
    var spawns: [(repoPath: String, command: String?)] = []
    var metas: [TerminalMeta] = []
    var kills: [TerminalID] = []
    var writeError: Error?

    func spawn(repoPath: String, task: String?, command: String?) throws -> TerminalMeta {
        spawns.append((repoPath, command))
        let meta = TerminalMeta(id: TerminalID(), name: "t", repoPath: repoPath,
                                createdAt: Date(), task: task, oscTitle: nil, status: .idle)
        metas.append(meta)
        return meta
    }
    func write(id: TerminalID, text: String) throws {
        if let writeError { throw writeError }
        writes.append((id, text))
    }
    func kill(id: TerminalID) throws { kills.append(id) }
    func killAll() {}
    func resize(id: TerminalID, cols: Int, rows: Int) {}
    func setFocused(_ id: TerminalID?) {}
    func setWindowFocused(_ focused: Bool) {}
    var terminals: [TerminalMeta] { metas }
    func setMaxTerminals(_ n: Int) {}
    func events() -> AsyncStream<TerminalEvent> { AsyncStream { $0.finish() } }
    func outputStream(id: TerminalID) -> AsyncStream<String>? { nil }
}

private actor FakePersonas: PersonaServicing {
    var spawned: [(personaID: String, repoPath: String)] = []
    private let meta: TerminalMeta

    init(meta: TerminalMeta) { self.meta = meta }
    func personas(projectPath: String?) async -> [Persona] { [] }
    func seedDefaults() async {}
    func spawn(personaID: String, repoPath: String) async throws -> TerminalMeta {
        spawned.append((personaID, repoPath))
        return meta
    }
    func events() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func spawnCount() -> Int { spawned.count }
}

@MainActor
final class RemoteCommandHandlerTests: XCTestCase {
    private func makeHandler() -> (RemoteCommandHandler, FakeTerminal) {
        let terminal = FakeTerminal()
        let personaMeta = TerminalMeta(id: TerminalID(), name: "p", repoPath: "/r",
                                       createdAt: Date(), task: nil, oscTitle: nil, status: .idle)
        let handler = RemoteCommandHandler(terminal: terminal, personas: FakePersonas(meta: personaMeta))
        return (handler, terminal)
    }

    private func makeHandlerWithZeroDelay() -> (RemoteCommandHandler, FakeTerminal) {
        let terminal = FakeTerminal()
        let personaMeta = TerminalMeta(id: TerminalID(), name: "p", repoPath: "/r",
                                       createdAt: Date(), task: nil, oscTitle: nil, status: .idle)
        let handler = RemoteCommandHandler(
            terminal: terminal,
            personas: FakePersonas(meta: personaMeta),
            personaPromptDelay: .zero)
        return (handler, terminal)
    }

    func testSendTextWritesWithEnter() async {
        let (handler, terminal) = makeHandler()
        let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
        terminal.spawns.removeAll()
        let result = await handler.handle([
            "commandId": "c1", "action": "send_text",
            "sessionId": meta.id.description, "text": "devam et",
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["commandId"] as? String, "c1")
        XCTAssertEqual(terminal.writes.count, 1)
        XCTAssertEqual(terminal.writes[0].1, "devam et\r")
    }

    func testPressKeyMapsAndRejectsUnknown() async {
        let (handler, terminal) = makeHandler()
        let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
        var result = await handler.handle([
            "commandId": "c2", "action": "press_key",
            "sessionId": meta.id.description, "key": "esc",
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(terminal.writes.last?.1, "\u{1B}")

        result = await handler.handle([
            "commandId": "c3", "action": "press_key",
            "sessionId": meta.id.description, "key": "delete-everything",
        ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "unknown_key")
    }

    func testUnknownSessionAndUnknownAction() async {
        let (handler, _) = makeHandler()
        var result = await handler.handle([
            "commandId": "c4", "action": "send_text",
            "sessionId": UUID().uuidString, "text": "x",
        ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "session_not_found")

        result = await handler.handle(["commandId": "c5", "action": "reboot"])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "unknown_action")
    }

    func testStartSessionWithoutPersonaSpawnsClaudeWithQuotedPrompt() async {
        let (handler, terminal) = makeHandler()
        let result = await handler.handle([
            "commandId": "c6", "action": "start_session",
            "repoPath": "/r", "prompt": "it's a bug; fix it",
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(terminal.spawns.count, 1)
        XCTAssertEqual(terminal.spawns[0].command, "claude 'it'\\''s a bug; fix it'")
    }

    func testShellQuoted() {
        XCTAssertEqual(shellQuoted("abc"), "'abc'")
        XCTAssertEqual(shellQuoted("a'b"), "'a'\\''b'")
        XCTAssertEqual(shellQuoted(""), "''")
    }

    func testWriteFailureSurfacesError() async {
        let (handler, terminal) = makeHandler()
        let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
        terminal.writeError = NSError(domain: "test", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "pty kapalı"])
        let result = await handler.handle([
            "commandId": "c7", "action": "send_text",
            "sessionId": meta.id.description, "text": "x",
        ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertNotNil(result["error"])
    }

    func testStartSessionWithPersonaAndPromptWritesPromptAfterDelay() async {
        let (handler, terminal) = makeHandlerWithZeroDelay()
        let result = await handler.handle([
            "commandId": "c8", "action": "start_session",
            "repoPath": "/r", "personaId": "engineer", "prompt": "merhaba",
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(terminal.writes.count, 1)
        XCTAssertEqual(terminal.writes[0].1, "merhaba\r")
        XCTAssertEqual(terminal.spawns.count, 0, "persona yolu terminal.spawn kullanmaz")
    }

    func testDeleteSessionKillsTerminal() async {
        let (handler, terminal) = makeHandler()
        let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
        let result = await handler.handle([
            "commandId": "d1", "action": "delete_session",
            "sessionId": meta.id.description,
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["commandId"] as? String, "d1")
        XCTAssertEqual(terminal.kills.count, 1)
        XCTAssertEqual(terminal.kills[0], meta.id)
    }

    func testDeleteSessionUnknownSessionFails() async {
        let (handler, _) = makeHandler()
        let result = await handler.handle([
            "commandId": "d2", "action": "delete_session",
            "sessionId": UUID().uuidString,
        ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "session_not_found")
    }
}
