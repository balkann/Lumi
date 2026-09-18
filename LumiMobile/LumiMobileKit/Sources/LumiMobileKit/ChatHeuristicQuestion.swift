import Foundation

// Orca `mobile/src/session/mobile-native-chat-question.ts` biREBIR portu.
// AI'ın metnindeki "bir seçenek seç" listesini sezgisel (heuristic) ayıklar:
// stream-json chat modunda AskUserQuestion tool'u YOK (kanıtlandı) → AI seçenekleri
// düz metin liste olarak sunar. Yapısal sinyal olmadığından metni TUTUCU biçimde
// ayrıştırırız; net bir seçenek listesi yoksa nil (sıradan prose soru sayılmaz).
// Cevap, seçilen seçeneğin işaretçisi/etiketi normal chat mesajı olarak gönderilir.

public struct ChatHeuristicQuestion: Equatable, Sendable {
    public let question: String
    public let options: [String]
    public let multiSelect: Bool
    /// Seçenek başına önek işaretçi ("1", "b", …) — kaynak satırda varsa; yoksa nil.
    /// Cevapta AI'ın listelediği tam işareti geri yollamak için.
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
    // Desenler sabit; derleme başarısızsa programlama hatası.
    try! NSRegularExpression(pattern: pattern, options: opts)
}

// TUI'nin SEÇİLİ satıra eklediği işaretçi glyph'i; önce sökülür ki "❯ 2. Foo"
// "2. Foo" ile aynı ayrıştırılsın (yakalanan baştaki boşluk korunur).
private let pointerPrefix = compile("^(\\s*)(?:❯|›|»)\\s+")

// En-özelden-genele sıralı: numaralı/harfli işaret, bullet fallback'ten önce kazanır.
private let optionPatterns: [OptionPattern] = [
    // 1. Option   12) Option
    OptionPattern(regex: compile("^\\s*(\\d{1,2})[.)]\\s+(\\S.*?)\\s*$"), token: 1, label: 2),
    // [a] Option   [1] Option
    OptionPattern(regex: compile("^\\s*\\[([0-9a-zA-Z])\\]\\s+(\\S.*?)\\s*$"), token: 1, label: 2),
    // a) Option   a. Option (tek harf; "e.g." gibi prose'u yememek için)
    OptionPattern(regex: compile("^\\s*([a-zA-Z])[.)]\\s+(\\S.*?)\\s*$"), token: 1, label: 2),
    // - Option   * Option   • Option   > Option (işaretçisiz)
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

/// AI metninden soru + seçenek listesini sezgisel ayıklar. Net liste yoksa nil.
/// Tutucu: en az 2 seçenek VEYA soru-benzeri (?/:) giriş satırıyla 1 seçenek.
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

    // Girişi bulan soru: ilk seçeneğin üstündeki en yakın boş-olmayan, seçenek-olmayan satır.
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

    // Tutucu kapı: giriş yoksa tek başına bir seçenek büyük olasılıkla stray prose.
    if options.count < 2 && !looksLikePrompt { return nil }

    let multiSelect = matches(multiSelectHint, text) && options.count > 1
    return ChatHeuristicQuestion(
        question: question.isEmpty ? "Bir seçenek seç" : cleanQuestionText(question),
        options: options, multiSelect: multiSelect, optionTokens: optionTokens)
}

private func optionAtIndex(_ q: ChatHeuristicQuestion, _ index: Int) -> String? {
    guard index >= 0, index < q.options.count else { return nil }
    let label = q.options[index]
    guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let token = q.optionTokens[index]
    return (token?.isEmpty == false) ? token : label
}

/// Seçili index'ler için AI'a gönderilecek cevap metni: işaretçi varsa onu, yoksa
/// etiketi; multi-select virgülle, single boşlukla birleşir (orca konvansiyonu).
public func formatChatQuestionAnswer(_ q: ChatHeuristicQuestion, selectedIndexes: [Int]) -> String {
    let parts = selectedIndexes.compactMap { optionAtIndex(q, $0) }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return parts.joined(separator: q.multiSelect ? ", " : " ")
}
