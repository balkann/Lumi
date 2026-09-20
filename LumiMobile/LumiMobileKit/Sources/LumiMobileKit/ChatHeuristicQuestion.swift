import Foundation

// Exact port of orca `mobile/src/session/mobile-native-chat-question.ts`.
// Heuristically extracts a "select an option" list from the AI's text:
// in stream-json chat mode the AskUserQuestion tool is ABSENT (proven) → the AI
// presents options as a plain-text list. With no structural signal we parse
// CONSERVATIVELY; nil is returned if no clear option list is found (ordinary
// prose questions are not counted). The answer is sent as a normal chat message
// containing the selected option's token/label.

public struct ChatHeuristicQuestion: Equatable, Sendable {
    public let question: String
    public let options: [String]
    public let multiSelect: Bool
    /// Per-option prefix token ("1", "b", …) — present when found in the source line; nil otherwise.
    /// Used to send back the exact token the AI listed in the answer.
    public let optionTokens: [String?]
    public init(question: String, options: [String], multiSelect: Bool, optionTokens: [String?]) {
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.optionTokens = optionTokens
    }
}

private struct OptionPattern { let regex: NSRegularExpression; let token: Int; let label: Int }

private func compile(_ pattern: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
    // Patterns are fixed; a compilation failure is a programming error.
    try! NSRegularExpression(pattern: pattern, options: opts)
}

// Pointer glyph added by the TUI to the SELECTED line; stripped first so "❯ 2. Foo"
// parses identically to "2. Foo" (captured leading space is preserved).
private let pointerPrefix = compile("^(\\s*)(?:❯|›|»)\\s+")

// Most-specific to least-specific: numbered/lettered tokens win over bullet fallback.
private let optionPatterns: [OptionPattern] = [
    // 1. Option   12) Option
    OptionPattern(regex: compile("^\\s*(\\d{1,2})[.)]\\s+(\\S.*?)\\s*$"), token: 1, label: 2),
    // [a] Option   [1] Option
    OptionPattern(regex: compile("^\\s*\\[([0-9a-zA-Z])\\]\\s+(\\S.*?)\\s*$"), token: 1, label: 2),
    // a) Option   a. Option (single letter; avoids swallowing prose like "e.g.")
    OptionPattern(regex: compile("^\\s*([a-zA-Z])[.)]\\s+(\\S.*?)\\s*$"), token: 1, label: 2),
    // - Option   * Option   • Option   > Option (no token)
    OptionPattern(regex: compile("^\\s*(?:[-*•>])\\s+(\\S.*?)\\s*$"), token: 0, label: 1),
]

private let multiSelectHint = compile(
    "\\b(select all|choose all|choose multiple|select multiple|pick multiple|all that apply|one or more|comma[- ]separated|multiple options)\\b",
    [.caseInsensitive])
private let questionLine = compile("[?:]\\s*$")

private func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
    guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return nil }
    return String(s[r])
}

private func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

private struct ParsedOption { let label: String; let token: String? }

private func parseOptionLine(_ line: String) -> ParsedOption? {
    let stripped = pointerPrefix.stringByReplacingMatches(
        in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1")
    for p in optionPatterns {
        guard let m = p.regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let label = group(m, p.label, in: stripped)?.trimmingCharacters(in: .whitespaces),
              !label.isEmpty else { continue }
        let token = p.token > 0 ? group(m, p.token, in: stripped) : nil
        return ParsedOption(label: label, token: token)
    }
    return nil
}

private func cleanQuestionText(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespaces)
    return t.hasSuffix(":") ? String(t.dropLast()).trimmingCharacters(in: .whitespaces) : t
}

/// Heuristically extracts a question + option list from the AI text. Returns nil if no clear list.
/// Conservative: requires at least 2 options OR 1 option with a question-like (?/:) intro line.
public func parseAgentQuestion(_ text: String) -> ChatHeuristicQuestion? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var parsed: [(index: Int, option: ParsedOption)] = []
    for (i, line) in lines.enumerated() {
        if let o = parseOptionLine(line) { parsed.append((i, o)) }
    }
    guard !parsed.isEmpty else { return nil }

    let firstOptionIndex = parsed[0].index
    let options = parsed.map { $0.option.label }
    let optionTokens = parsed.map { $0.option.token }

    // Question that introduces the options: the nearest non-empty, non-option line above the first option.
    var question = ""
    var looksLikePrompt = false
    var i = firstOptionIndex - 1
    while i >= 0 {
        let l = lines[i]
        if l.trimmingCharacters(in: .whitespaces).isEmpty || parseOptionLine(l) != nil { i -= 1; continue }
        question = l
        looksLikePrompt = matches(questionLine, l)
        break
    }

    // Conservative gate: a lone option without an intro line is most likely stray prose.
    if options.count < 2 && !looksLikePrompt { return nil }

    let multiSelect = matches(multiSelectHint, text) && options.count > 1
    return ChatHeuristicQuestion(
        question: question.isEmpty ? "Select an option" : cleanQuestionText(question),
        options: options, multiSelect: multiSelect, optionTokens: optionTokens)
}

private func optionAtIndex(_ q: ChatHeuristicQuestion, _ index: Int) -> String? {
    guard index >= 0, index < q.options.count else { return nil }
    let label = q.options[index]
    guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let token = q.optionTokens[index]
    return (token?.isEmpty == false) ? token : label
}

/// Answer text to send to the AI for the selected indexes: uses the token if present,
/// otherwise the label; multi-select joins with comma, single joins with space (orca convention).
public func formatChatQuestionAnswer(_ q: ChatHeuristicQuestion, selectedIndexes: [Int]) -> String {
    let parts = selectedIndexes.compactMap { optionAtIndex(q, $0) }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return parts.joined(separator: q.multiSelect ? ", " : " ")
}
