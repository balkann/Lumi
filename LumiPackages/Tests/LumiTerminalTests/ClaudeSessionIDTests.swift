import XCTest
@testable import LumiTerminal

final class ClaudeSessionIDTests: XCTestCase {
    func testInjectsIntoPlainClaude() {
        XCTAssertEqual(
            ClaudeSessionID.inject(into: "claude", sessionId: "abc"),
            "claude --session-id abc")
    }

    func testInjectsBeforePromptAndFlags() {
        XCTAssertEqual(
            ClaudeSessionID.inject(into: "claude 'fix bug'", sessionId: "abc"),
            "claude --session-id abc 'fix bug'")
        XCTAssertEqual(
            ClaudeSessionID.inject(into: "claude --model opus -- hi", sessionId: "abc"),
            "claude --session-id abc --model opus -- hi")
    }

    func testLeavesNonClaudeUnchanged() {
        XCTAssertEqual(ClaudeSessionID.inject(into: "codex", sessionId: "abc"), "codex")
        XCTAssertEqual(ClaudeSessionID.inject(into: "bash", sessionId: "abc"), "bash")
        // "claude" ön eki ama kelime sınırı değil → dokunma
        XCTAssertEqual(ClaudeSessionID.inject(into: "claudexyz", sessionId: "abc"), "claudexyz")
    }

    func testIdempotentWhenSessionIdAlreadyPresent() {
        let cmd = "claude --session-id existing 'p'"
        XCTAssertEqual(ClaudeSessionID.inject(into: cmd, sessionId: "abc"), cmd)
    }
}
