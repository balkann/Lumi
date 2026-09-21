import XCTest
@testable import LumiTerminal

final class CodexSessionCommandTests: XCTestCase {
    func testResumeCommandUsesExactThreadAndFallsBackToFreshCodex() throws {
        let command = try XCTUnwrap(CodexSessionCommand.resumeCommand(sessionID: "thread-123"))
        XCTAssertEqual(command, "codex resume 'thread-123' || codex")
        XCTAssertEqual(CodexSessionCommand.resumedSessionID(from: command), "thread-123")
    }

    func testUnsafeThreadCannotBecomeAResumeArgument() {
        XCTAssertNil(CodexSessionCommand.resumeCommand(sessionID: "--last"))
        XCTAssertNil(CodexSessionCommand.resumeCommand(sessionID: "bad\nthread"))
        XCTAssertNil(CodexSessionCommand.resumedSessionID(from: "codex resume --last"))
    }
}
