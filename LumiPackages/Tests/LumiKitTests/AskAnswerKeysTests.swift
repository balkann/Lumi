import Testing
@testable import LumiKit

@Suite struct AskAnswerKeysTests {
    private func q(_ opts: [String], multi: Bool = false) -> AskQuestionInput {
        AskQuestionInput(question: "Q", header: nil, multiSelect: multi, optionLabels: opts)
    }

    // MARK: - Claude buildAskAnswerKeys

    @Test func singleQuestionSingleSelect() {
        let g = buildAskAnswerKeys(questions: [q(["A", "B"])], selections: [AskSelection(indices: [1], other: nil)])
        #expect(g == [.raw("2")])
    }

    @Test func singleQuestionMultiSelect() {
        let g = buildAskAnswerKeys(questions: [q(["A", "B", "C"], multi: true)],
                                   selections: [AskSelection(indices: [0, 2], other: nil)])
        #expect(g == [.raw("1"), .raw("3"), .raw("\u{1b}[C"), .raw("\r")])
    }

    @Test func groupedMultiQuestionSingleSelect() {
        let g = buildAskAnswerKeys(questions: [q(["A", "B"]), q(["C", "D", "E"])],
                                   selections: [AskSelection(indices: [1], other: nil), AskSelection(indices: [2], other: nil)])
        #expect(g == [.raw("2"), .raw("3"), .raw("\r")])
    }

    @Test func singleSelectFreeText() {
        let g = buildAskAnswerKeys(questions: [q(["A", "B"])], selections: [AskSelection(indices: [], other: "hello")])
        #expect(g == [.raw("3"), .text("hello"), .raw("\r")])
    }

    @Test func multiSelectWithOther() {
        let g = buildAskAnswerKeys(questions: [q(["A", "B"], multi: true)],
                                   selections: [AskSelection(indices: [0], other: "x")])
        #expect(g == [.raw("1"), .raw("3"), .text("x"), .raw("\r"), .raw("\u{1b}[C"), .raw("\r")])
    }

    @Test func unansweredMiddleQuestionSteps() {
        let g = buildAskAnswerKeys(questions: [q(["A"]), q(["C", "D"])],
                                   selections: [AskSelection(indices: [], other: nil), AskSelection(indices: [1], other: nil)])
        #expect(g == [.raw("\u{1b}[C"), .raw("2"), .raw("\r")])
    }

    // MARK: - Codex buildCodexAskAnswerKeys

    @Test func codexSingleSelectNoTrailingEnter() {
        let g = buildCodexAskAnswerKeys(questions: [q(["A", "B"])], selections: [AskSelection(indices: [1], other: nil)])
        #expect(g == [.raw("2")])
    }

    @Test func codexGroupedSelect() {
        let g = buildCodexAskAnswerKeys(questions: [q(["A", "B"]), q(["C", "D"])],
                                        selections: [AskSelection(indices: [1], other: nil), AskSelection(indices: [0], other: nil)])
        #expect(g == [.raw("2"), .raw("1")])
    }

    @Test func codexUnansweredBackspaceThenEnter() {
        let g = buildCodexAskAnswerKeys(questions: [q(["A", "B"])], selections: [AskSelection(indices: [], other: nil)])
        #expect(g == [.raw("\u{7f}"), .raw("\r"), .raw("\r")])
    }

    @Test func codexNoteNavigatesAndTabs() {
        let g = buildCodexAskAnswerKeys(questions: [q(["A", "B"])], selections: [AskSelection(indices: [], other: "note")])
        #expect(g == [.raw("\u{1b}[A"), .raw("\t"), .text("note"), .raw("\r")])
    }
}
