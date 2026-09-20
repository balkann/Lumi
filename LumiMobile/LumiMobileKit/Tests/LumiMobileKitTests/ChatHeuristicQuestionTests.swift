import XCTest
@testable import LumiMobileKit

final class ChatHeuristicQuestionTests: XCTestCase {

    func testNumberedOptionsWithQuestion() {
        let q = parseAgentQuestion("Which do you prefer?\n1. Tea\n2. Coffee")
        XCTAssertNotNil(q)
        XCTAssertEqual(q?.question, "Which do you prefer?")
        XCTAssertEqual(q?.options, ["Tea", "Coffee"])
        XCTAssertEqual(q?.optionTokens, ["1", "2"])
        XCTAssertEqual(q?.multiSelect, false)
    }

    func testParenNumberedAndPointerStripped() {
        // The ❯ pointer on the selected line must be stripped.
        let q = parseAgentQuestion("Selection:\n❯ 1) Alpha\n2) Beta")
        XCTAssertEqual(q?.options, ["Alpha", "Beta"])
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
        // A lone bullet without an intro question → treated as prose, returns nil.
        XCTAssertNil(parseAgentQuestion("Here is a note\n- just one item"))
    }

    func testSingleOptionWithQuestionPromptIsAccepted() {
        // A question-like intro line (?/:) makes even a single option acceptable.
        let q = parseAgentQuestion("Should I continue?\n1. Yes")
        XCTAssertEqual(q?.options, ["Yes"])
    }

    func testPlainProseReturnsNil() {
        XCTAssertNil(parseAgentQuestion("This is just a normal answer sentence, no options."))
        XCTAssertNil(parseAgentQuestion(""))
    }

    func testMultiSelectHint() {
        let q = parseAgentQuestion("Select all that apply:\n1. A\n2. B\n3. C")
        XCTAssertEqual(q?.multiSelect, true)
    }

    func testFormatAnswerUsesTokenThenLabel() {
        let q = ChatHeuristicQuestion(question: "q", options: ["Tea", "Coffee"],
                                      multiSelect: false, optionTokens: ["1", "2"])
        XCTAssertEqual(formatChatQuestionAnswer(q, selectedIndexes: [1]), "2")
        // No token → use the label:
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
