import Foundation

public struct Question: Equatable, Sendable {
    let header: String
    let question: String
    let options: [String]

    init(header: String, question: String, options: [String]) {
        self.header = header
        self.question = question
        self.options = options
    }
}

/// Telefona giden sadeleştirilmiş akış birimi (spec §5 tablosu).
public enum FeedItem: Equatable, Sendable {
    case assistantText(String)
    case toolUse(name: String, summary: String)
    case question(payload: [Question])
    case turnDone

    /// Yalnız item sözlüğü — hem canlı `transcript` event'inde hem `history`
    /// yanıtında aynı şekil kullanılır (protokol: items[] elemanı).
    var itemPayload: [String: Any] {
        switch self {
        case .assistantText(let text):
            return ["itemType": "assistant_text", "text": text]
        case .toolUse(let name, let summary):
            return ["itemType": "tool_use", "tool": name, "summary": summary]
        case .question(let questions):
            return ["itemType": "question", "questions": questions.map {
                ["header": $0.header, "question": $0.question, "options": $0.options]
            }]
        case .turnDone:
            return ["itemType": "turn_done"]
        }
    }

    func eventPayload(sessionId: String) -> [String: Any] {
        ["kind": "transcript", "sessionId": sessionId, "item": itemPayload]
    }
}

/// Claude Code transcript jsonl kayıtlarını FeedItem'lara çevirir.
/// Format Anthropic'in iç formatı — toleranslı parse: bilinmeyen/bozuk
/// kayıtlar sessizce atlanır (tasarım riski §12.2).
enum TranscriptParser {
    /// cwd → ~/.claude/projects altındaki dizin adı: alfanümerik olmayan her karakter `-`.
    static func projectDirName(forCwd cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func parse(line: String) -> [FeedItem] {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["type"] as? String == "assistant",
              let message = dict["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }

        var items: [FeedItem] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    items.append(.assistantText(text))
                }
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                if name == "AskUserQuestion", let questions = parseQuestions(input) {
                    items.append(.question(payload: questions))
                } else {
                    items.append(.toolUse(name: name, summary: toolSummary(input)))
                }
            default:
                break // thinking vb. atlanır
            }
        }
        if message["stop_reason"] as? String == "end_turn" {
            items.append(.turnDone)
        }
        return items
    }

    /// Tek satırlık tool özeti: description > file_path'in son bileşeni > command > "".
    private static func toolSummary(_ input: [String: Any]) -> String {
        if let description = input["description"] as? String { return description }
        if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        if let command = input["command"] as? String { return command }
        return ""
    }

    private static func parseQuestions(_ input: [String: Any]) -> [Question]? {
        guard let raw = input["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        return raw.compactMap { q in
            guard let question = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? [])
                .compactMap { $0["label"] as? String }
            return Question(
                header: q["header"] as? String ?? "",
                question: question,
                options: options
            )
        }
    }
}
