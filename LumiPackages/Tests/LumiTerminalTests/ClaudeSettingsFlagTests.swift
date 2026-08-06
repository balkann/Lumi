import XCTest
@testable import LumiTerminal

final class ClaudeSettingsFlagTests: XCTestCase {
    func testInjectsSettingsIntoClaude() {
        let out = ClaudeSettingsFlag.inject(into: "claude --session-id abc", settingsPath: "/x/s.json")
        XCTAssertEqual(out, "claude --settings '/x/s.json' --session-id abc")
    }
    func testLeavesNonClaudeUntouched() {
        XCTAssertEqual(ClaudeSettingsFlag.inject(into: "git pull", settingsPath: "/x/s.json"), "git pull")
    }
    func testDoesNotDoubleInject() {
        let cmd = "claude --settings '/y.json'"
        XCTAssertEqual(ClaudeSettingsFlag.inject(into: cmd, settingsPath: "/x/s.json"), cmd)
    }
}
