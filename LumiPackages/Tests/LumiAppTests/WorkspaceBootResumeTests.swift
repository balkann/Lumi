import Foundation
import LumiKit
import XCTest
@testable import LumiAppCore

@MainActor
final class WorkspaceBootResumeTests: XCTestCase {
    func testCapturesClaudeAndCodexWithOriginHome() {
        let claude = TerminalMeta(
            id: TerminalID(),
            name: "Claude",
            repoPath: "/repo/claude",
            createdAt: .distantPast,
            claudeSessionID: "11111111-2222-3333-4444-555555555555",
            provider: .claude
        )
        let codex = TerminalMeta(
            id: TerminalID(),
            name: "Codex",
            repoPath: "/repo/codex",
            createdAt: .distantPast,
            codexSessionID: "thread-123",
            codexHome: "/Users/dev/.codex",
            provider: .codex
        )

        XCTAssertEqual(WorkspaceBootAssembly.resumeSessions(from: [claude, codex]), [
            ResumeSession(
                repoPath: "/repo/claude",
                sessionID: "11111111-2222-3333-4444-555555555555"
            ),
            ResumeSession(
                repoPath: "/repo/codex",
                sessionID: "thread-123",
                provider: .codex,
                codexHome: "/Users/dev/.codex"
            ),
        ])
    }

    func testDoesNotPersistCodexWithoutAuthoritativeHookThread() {
        let codex = TerminalMeta(
            id: TerminalID(),
            name: "Codex",
            repoPath: "/repo",
            createdAt: .distantPast,
            codexHome: "/Users/dev/.codex",
            provider: .codex
        )
        XCTAssertTrue(WorkspaceBootAssembly.resumeSessions(from: [codex]).isEmpty)
    }
}
