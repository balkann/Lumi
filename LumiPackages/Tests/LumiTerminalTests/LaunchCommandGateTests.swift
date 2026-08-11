import XCTest
@testable import LumiTerminal

final class LaunchCommandGateTests: XCTestCase {
    private let shellPrompt = ["", "➜  sandout_word-puzzle git:(main)", ""]
    private let omzQuestion = [
        "Last login: Tue Aug 11 09:12:44 on ttys003",
        "[oh-my-zsh] Would you like to update? [Y/n] ",
        "",
    ]

    func testInjectsAtQuiescenceWithPlainPrompt() {
        var gate = LaunchCommandGate()
        gate.arm("claude --session-id abc")
        XCTAssertEqual(gate.commandToInject(bottomLines: shellPrompt), "claude --session-id abc")
    }

    func testInjectsOnlyOnce() {
        var gate = LaunchCommandGate()
        gate.arm("claude")
        XCTAssertTrue(gate.isPending)
        XCTAssertEqual(gate.commandToInject(bottomLines: shellPrompt), "claude")
        XCTAssertFalse(gate.isPending)
        XCTAssertNil(gate.commandToInject(bottomLines: shellPrompt))
    }

    func testNotArmedReturnsNil() {
        var gate = LaunchCommandGate()
        XCTAssertNil(gate.commandToInject(bottomLines: shellPrompt))
    }

    func testHoldsWhileSingleKeyQuestionOnScreen() {
        var gate = LaunchCommandGate()
        gate.arm("claude")
        XCTAssertNil(gate.commandToInject(bottomLines: omzQuestion))
        // Soru kapanınca (kullanıcı cevapladı, yeni prompt geldi) enjekte edilir.
        XCTAssertEqual(gate.commandToInject(bottomLines: shellPrompt), "claude")
    }

    func testHoldsOnQuestionVariants() {
        let variants = [
            "Update now? [y/N]",
            "Continue (y/n)",
            "Proceed [Y/n]:",
            "install? (Y/N)? ",
        ]
        for lastLine in variants {
            var gate = LaunchCommandGate()
            gate.arm("claude")
            XCTAssertNil(
                gate.commandToInject(bottomLines: ["önceki çıktı", lastLine]),
                "beklemeliydi: \(lastLine)")
        }
    }

    func testDoesNotHoldWhenQuestionIsNotAtLineEnd() {
        // Satır ortasında geçen [Y/n] cevap bekleyen soru değildir (örn. echo'lu log).
        var gate = LaunchCommandGate()
        gate.arm("claude")
        XCTAssertEqual(
            gate.commandToInject(bottomLines: ["[Y/n] sorusuna c ile cevap verildi", "$"]),
            "claude")
    }

    func testIgnoresTrailingEmptyLinesWhenDetectingQuestion() {
        // Ekranın altı boş satırlarla dolu — karar son DOLU satıra göre verilir.
        var gate = LaunchCommandGate()
        gate.arm("claude")
        XCTAssertNil(
            gate.commandToInject(bottomLines: ["Would you like to update? [Y/n] ", "", "", ""]))
    }

    func testAllEmptyScreenHolds() {
        // Hiç çıktı görünmüyorsa shell hazır sayılmaz; bekle.
        var gate = LaunchCommandGate()
        gate.arm("claude")
        XCTAssertNil(gate.commandToInject(bottomLines: ["", "", ""]))
    }
}
