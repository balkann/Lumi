import XCTest
@testable import LumiTerminal
import LumiKit

final class TerminalSessionEnvTests: XCTestCase {
    func testBuildsEnvironmentWithTerminalID() {
        let id = TerminalID()
        let env = TerminalSession.childEnvironment(base: ["PATH": "/usr/bin"], terminalID: id)
        XCTAssertEqual(env["LUMI_TERMINAL_ID"], id.raw.uuidString.lowercased())
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["PATH"], "/usr/bin", "taban env korunmalı")
    }

    func testDefaultsLangWhenAbsent() {
        let id = TerminalID()
        let env = TerminalSession.childEnvironment(base: [:], terminalID: id)
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
    }
}
