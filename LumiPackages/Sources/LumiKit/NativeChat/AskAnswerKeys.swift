import Foundation

/// orca `buildAskAnswerKeys` / `buildCodexAskAnswerKeys` port'u (Faz 3.1) — AskUserQuestion
/// cevabını PTY keystroke grup dizisine çevirir. `.raw` ham tuş(lar), `.text` free-text
/// (çağıran paste-sanitize eder). Saf/deterministik; kaynak: orca `native-chat-ask.ts`.
public enum KeyGroup: Equatable, Sendable { case raw(String); case text(String) }

public struct AskSelection: Equatable, Sendable {
    public var indices: [Int]
    public var other: String?
    public init(indices: [Int], other: String?) { self.indices = indices; self.other = other }
}

public struct AskQuestionInput: Equatable, Sendable {
    public var question: String
    public var header: String?
    public var multiSelect: Bool
    public var optionLabels: [String]
    public init(question: String, header: String?, multiSelect: Bool, optionLabels: [String]) {
        self.question = question; self.header = header
        self.multiSelect = multiSelect; self.optionLabels = optionLabels
    }
}

private let ASK_ENTER = "\r"
private let ASK_NEXT_TAB = "\u{1b}[C"
private let ASK_PREV_ROW = "\u{1b}[A"
private let ASK_NEXT_ROW = "\u{1b}[B"
private let ASK_NOTES = "\t"

/// orca answerLabels: seçili label'lar + trim'li other (option sırasında).
private func answerLabels(_ q: AskQuestionInput, _ sel: AskSelection?) -> [String] {
    let labels = (sel?.indices ?? []).compactMap { i -> String? in
        guard i >= 0, i < q.optionLabels.count else { return nil }
        let l = q.optionLabels[i]
        return l.isEmpty ? nil : l
    }
    let other = (sel?.other ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return other.isEmpty ? labels : labels + [other]
}

/// Claude AskUserQuestion (orca `native-chat-ask.ts:204-249`).
public func buildAskAnswerKeys(questions: [AskQuestionInput], selections: [AskSelection]) -> [KeyGroup] {
    let multiQuestion = questions.count > 1
    var groups: [KeyGroup] = []
    for (qi, q) in questions.enumerated() {
        let sel = qi < selections.count ? selections[qi] : nil
        let other = (sel?.other ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let typeSomething = String(q.optionLabels.count + 1)
        if q.multiSelect {
            for i in (sel?.indices ?? []) { groups.append(.raw(String(i + 1))) }
            if !other.isEmpty { groups += [.raw(typeSomething), .text(other), .raw(ASK_ENTER)] }
            groups.append(.raw(ASK_NEXT_TAB))
        } else if !other.isEmpty {
            groups += [.raw(typeSomething), .text(answerLabels(q, sel).joined(separator: ", ")), .raw(ASK_ENTER)]
        } else if !(sel?.indices.isEmpty ?? true) {
            groups.append(.raw(String(sel!.indices[0] + 1)))
        } else if multiQuestion {
            groups.append(.raw(ASK_NEXT_TAB))
        }
    }
    let endsOnSubmitTab = multiQuestion || (questions.count == 1 && questions[0].multiSelect)
    if endsOnSubmitTab && !groups.isEmpty { groups.append(.raw(ASK_ENTER)) }
    return groups
}

/// Codex varyantı (orca `native-chat-ask.ts:257-304`): digit hem seçer hem gönderir (sonda
/// Enter yok); note `\t`; cevapsız `\x7f` + adım; en-kısa yol ok-navigasyonu.
public func buildCodexAskAnswerKeys(questions: [AskQuestionInput], selections: [AskSelection]) -> [KeyGroup] {
    var groups: [KeyGroup] = []
    var hasUnanswered = false
    for (qi, q) in questions.enumerated() {
        let sel = qi < selections.count ? selections[qi] : nil
        let selectedIndex = sel?.indices.first
        let note = (sel?.other ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            let target = selectedIndex ?? q.optionLabels.count
            let rowCount = q.optionLabels.count + 1
            let nextSteps = target
            let previousSteps = rowCount - target
            let usePrevious = previousSteps < nextSteps
            let navKey = usePrevious ? ASK_PREV_ROW : ASK_NEXT_ROW
            let steps = usePrevious ? previousSteps : nextSteps
            for _ in 0..<steps { groups.append(.raw(navKey)) }
            groups += [.raw(ASK_NOTES), .text(note), .raw(ASK_ENTER)]
            continue
        }
        if let i = selectedIndex { groups.append(.raw(String(i + 1))); continue }
        hasUnanswered = true
        groups.append(.raw("\u{7f}"))
        if qi < questions.count - 1 { groups.append(.raw(ASK_NEXT_TAB)) } else { groups.append(.raw(ASK_ENTER)) }
    }
    if hasUnanswered { groups.append(.raw(ASK_ENTER)) }
    return groups
}
