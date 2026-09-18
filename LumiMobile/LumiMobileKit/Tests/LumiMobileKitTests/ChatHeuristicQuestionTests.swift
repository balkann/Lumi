import XCTest
@testable import LumiMobileKit

final class ChatHeuristicQuestionTests: XCTestCase {

    func testNumberedOptionsWithQuestion() {
        let q = parseAgentQuestion("Hangisini tercih edersin?\n1. Çay\n2. Kahve")
        XCTAssertNotNil(q)
        XCTAssertEqual(q?.question, "Hangisini tercih edersin?")
        XCTAssertEqual(q?.options, ["Çay", "Kahve"])
        XCTAssertEqual(q?.optionTokens, ["1", "2"])
        XCTAssertEqual(q?.multiSelect, false)
    }

    func testParenNumberedAndPointerStripped() {
        // Seçili satırdaki ❯ işaretçisi sökülmeli.
        let q = parseAgentQuestion("Seçim:\n❯ 1) Alfa\n2) Beta")
        XCTAssertEqual(q?.options, ["Alfa", "Beta"])
        XCTAssertEqual(q?.optionTokens, ["1", "2"])
    }

    func testBracketAndLetterTokens() {
        let q = parseAgentQuestion("Pick one:\n[a] Apple\nb) Banana")
        XCTAssertEqual(q?.options, ["Apple", "Banana"])
        XCTAssertEqual(q?.optionTokens, ["a", "b"])
    }

    func testBulletsHaveNilTokens() {
        let q = parseAgentQuestion("Options:\n- Red\n* Green\n• Blue")
        XCTAssertEqual(q?.options, ["Red", "Green", "Blue"])
        XCTAssertEqual(q?.optionTokens, [nil, nil, nil])
    }

    func testSingleBareOptionWithoutPromptIsNotAQuestion() {
        // Tek başına bir bullet, giriş sorusu yoksa → prose, nil.
        XCTAssertNil(parseAgentQuestion("Here is a note\n- just one item"))
    }

    func testSingleOptionWithQuestionPromptIsAccepted() {
        // Soru-benzeri giriş satırı (?/:) varsa tek seçenek de kabul.
        let q = parseAgentQuestion("Devam edeyim mi?\n1. Evet")
        XCTAssertEqual(q?.options, ["Evet"])
    }

    func testPlainProseReturnsNil() {
        XCTAssertNil(parseAgentQuestion("Bu sadece normal bir cevap cümlesi, seçenek yok."))
        XCTAssertNil(parseAgentQuestion(""))
    }

    func testMultiSelectHint() {
        let q = parseAgentQuestion("Select all that apply:\n1. A\n2. B\n3. C")
        XCTAssertEqual(q?.multiSelect, true)
    }

    func testFormatAnswerUsesTokenThenLabel() {
        let q = ChatHeuristicQuestion(question: "q", options: ["Çay", "Kahve"],
                                      multiSelect: false, optionTokens: ["1", "2"])
        XCTAssertEqual(formatChatQuestionAnswer(q, selectedIndexes: [1]), "2")
        // Token yoksa etiket:
        let q2 = ChatHeuristicQuestion(question: "q", options: ["Red", "Green"],
                                       multiSelect: false, optionTokens: [nil, nil])
        XCTAssertEqual(formatChatQuestionAnswer(q2, selectedIndexes: [0]), "Red")
    }

    func testFormatMultiSelectCommaJoined() {
        let q = ChatHeuristicQuestion(question: "q", options: ["A", "B", "C"],
                                      multiSelect: true, optionTokens: ["1", "2", "3"])
        XCTAssertEqual(formatChatQuestionAnswer(q, selectedIndexes: [0, 2]), "1, 3")
    }
}
