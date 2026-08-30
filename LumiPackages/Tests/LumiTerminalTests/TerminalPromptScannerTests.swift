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

    // image 1'deki gerçek "Owner" düzeni: sarılan açıklama satırları + şıklar arası
    // yatay ayraç çizgileri (─). Ayraçlar sarılan-seçenek diye şık etiketine eklenmemeli.
    func testAskUserQuestionWithDividerLines() {
        let lines = [
            "□ Owner",
            "",
            "Muhammed Alperen İnce'nin Plastic kullanıcı adı/e-postası ne? (shelve'i owner ile filtrelemek için)",
            "",
            "1. Bilmiyorum, listede bul",
            "   Tüm shelve'leri listeleyip comment/owner'dan onun ECS-time-isolation shelve'ini tespit edeceğim.",
            "2. Yazacağım",
            "   Kullanıcı adını/e-postasını vereceğim, owner ile direkt filtreleyeceğim.",
            "3. Type something.",
            "──────────────────────────────────────",
            "4. Chat about this",
            "──────────────────────────────────────",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        let p = TerminalPromptScanner.scan(lines: lines)
        XCTAssertEqual(p?.kind, .question)
        XCTAssertEqual(p?.questionText,
                       "Muhammed Alperen İnce'nin Plastic kullanıcı adı/e-postası ne? (shelve'i owner ile filtrelemek için)")
        XCTAssertEqual(p?.options, [
            "Bilmiyorum, listede bul Tüm shelve'leri listeleyip comment/owner'dan onun ECS-time-isolation shelve'ini tespit edeceğim.",
            "Yazacağım Kullanıcı adını/e-postasını vereceğim, owner ile direkt filtreleyeceğim.",
            "Type something.",
            "Chat about this",
        ])
    }

    func testNormalOutputHasNoPrompt() {
        let lines = ["$ ls", "file1.txt  file2.txt", "$ "]
        XCTAssertNil(TerminalPromptScanner.scan(lines: lines))
    }

    // Claude olmayan üçüncü-parti CLI menüsü (footer YOK): 1'den ardışık numaralı,
    // ekranın en altına yaslı blok → footer olmadan da .generic olarak yakalanır.
    func testFooterlessNumberedMenuDetected() {
        let lines = [
            "How would you like to authenticate?",
            "1. Sign in with your browser (SSO)",
            "2. User and password",
            "3. Token",
            "",
        ]
        let p = TerminalPromptScanner.scan(lines: lines)
        XCTAssertEqual(p?.kind, .generic)
        XCTAssertEqual(p?.questionText, "How would you like to authenticate?")
        XCTAssertEqual(p?.options, [
            "Sign in with your browser (SSO)", "User and password", "Token",
        ])
    }

    // Footer yoksa VE numaralı blok en altta değilse (altında başka çıktı var) → prompt sayma.
    func testFooterlessWithTrailingOutputIsNil() {
        let lines = [
            "1. apple",
            "2. banana",
            "3. cherry",
            "Done. Wrote 3 items to disk.",
            "$ ",
        ]
        XCTAssertNil(TerminalPromptScanner.scan(lines: lines))
    }

    // Footer yoksa VE numaralar 1'den ardışık değilse (log/liste görünümü) → prompt sayma.
    func testFooterlessNonSequentialIsNil() {
        let lines = [
            "12. fix build",
            "13. update deps",
            "",
        ]
        XCTAssertNil(TerminalPromptScanner.scan(lines: lines))
    }

    // Ham ekran tail'i: parse edilemeyen bekleyen prompt için son dolu satırlar
    // (kutu-çizgi ayıklanmış, boş satırlar atılmış, en fazla N satır).
    func testScreenTailKeepsLastNonEmptyCleanedLines() {
        let lines = [
            "$ cm login",
            "",
            "│ Select authentication │",
            "  browser / token ?",
            "",
            "",
        ]
        XCTAssertEqual(TerminalPromptScanner.screenTail(lines: lines, max: 6), [
            "$ cm login", "Select authentication", "browser / token ?",
        ])
    }

    func testScreenTailCapsToMax() {
        let lines = (1...10).map { "line \($0)" }
        XCTAssertEqual(TerminalPromptScanner.screenTail(lines: lines, max: 3),
                       ["line 8", "line 9", "line 10"])
    }

    func testFooterWithoutOptionsIsNil() {
        let lines = ["Loading…", "Enter to select · ↑/↓ to navigate"]
        XCTAssertNil(TerminalPromptScanner.scan(lines: lines))
    }
}
