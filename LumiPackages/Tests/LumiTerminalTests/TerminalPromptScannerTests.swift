import XCTest
import LumiKit
@testable import LumiTerminal

final class TerminalPromptScannerTests: XCTestCase {
    func testAskUserQuestionMenu() {
        let lines = [
            "",
            "□ Görsel adım",
            "",
            "Version review ekranı şu an sade baseline. Nasıl ilerleyelim?",
            "",
            "❯ 1. Önce frontend-design polish, sonra localhost onay",
            "  2. Önce baseline'ı localhost'ta göreyim",
            "  3. Polish'i atla, baseline'ı gönderelim",
            "  4. Type something.",
            "  5. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        let p = TerminalPromptScanner.scan(lines: lines)
        XCTAssertEqual(p?.kind, .question)
        XCTAssertEqual(p?.questionText,
                       "Version review ekranı şu an sade baseline. Nasıl ilerleyelim?")
        XCTAssertEqual(p?.options, [
            "Önce frontend-design polish, sonra localhost onay",
            "Önce baseline'ı localhost'ta göreyim",
            "Polish'i atla, baseline'ı gönderelim",
            "Type something.",
            "Chat about this",
        ])
    }

    func testSkillPermissionWithWrappedOption() {
        let lines = [
            "  Design guidance and fundamentals for Artifacts.",
            "",
            "Do you want to proceed?",
            "❯ 1. Yes",
            "  2. Yes, and don't ask again for artifact-design in",
            "     /Users/balkan/Desktop/side-projects/unco-forge",
            "  3. No",
            "",
            "Esc to cancel · Tab to amend",
        ]
        let p = TerminalPromptScanner.scan(lines: lines)
        XCTAssertEqual(p?.kind, .permission)
        XCTAssertEqual(p?.questionText, "Do you want to proceed?")
        XCTAssertEqual(p?.options, [
            "Yes",
            "Yes, and don't ask again for artifact-design in /Users/balkan/Desktop/side-projects/unco-forge",
            "No",
        ])
    }

    func testNormalOutputHasNoPrompt() {
        let lines = ["$ ls", "file1.txt  file2.txt", "$ "]
        XCTAssertNil(TerminalPromptScanner.scan(lines: lines))
    }

    func testFooterWithoutOptionsIsNil() {
        let lines = ["Loading…", "Enter to select · ↑/↓ to navigate"]
        XCTAssertNil(TerminalPromptScanner.scan(lines: lines))
    }
}
