import Foundation
import LumiKit

/// Claude transcript JSONL satırını `ChatMessage`'a çevirir (orca
/// `transcript-line-decoders-claude.ts` Faz 1 alt kümesi). Blok-farkındalıklı:
/// `message.content` dizisini text/tool_use/tool_result olarak yürür.
struct ClaudeTranscriptChatDecoder {
    private static let maxPreview = 200
    private static let maxOutput = 4000

    func decode(_ record: [String: Any], index: Int) -> ChatMessage? {
        guard record["isMeta"] as? Bool != true else { return nil }
        let kind = record["type"] as? String
        let role: ChatRole
        switch kind {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        let content = (record["message"] as? [String: Any])?["content"]
        let blocks = decodeBlocks(content)
        guard !blocks.isEmpty else { return nil }
        let id = (record["uuid"] as? String) ?? "idx-\(index)"
        return ChatMessage(
            id: id, role: role, blocks: blocks,
            timestampMs: timestampMs(record["timestamp"] as? String),
            turnId: id
        )
    }

    private func decodeBlocks(_ content: Any?) -> [ChatBlock] {
        if let string = content as? String {
            let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [.text(t, presentation: nil)]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let text = (block["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return .text(text, presentation: nil)
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                return .toolCall(name: name, inputPreview: preview(block["input"]), state: "completed")
            case "tool_result":
                return .toolResult(output: output(block["content"]),
                                   isError: block["is_error"] as? Bool ?? false)
            default:
                return nil
            }
        }
    }

    /// tool_use.input → tek satır kısa önizleme (JSON değerlerini düzleştir).
    private func preview(_ input: Any?) -> String {
        let text: String
        if let s = input as? String { text = s }
        else if let d = input as? [String: Any] {
            text = d.map { "\($0.key)=\(flatten($0.value))" }.sorted().joined(separator: " ")
        } else { text = "" }
        return String(text.prefix(Self.maxPreview))
    }

    private func output(_ content: Any?) -> String {
        let text: String
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else { text = "" }
        return String(text.prefix(Self.maxOutput))
    }

    private func flatten(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value).prefix(80).description
    }

    private func timestampMs(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let styles = [Date.ISO8601FormatStyle(includingFractionalSeconds: true),
                      Date.ISO8601FormatStyle()]
        for style in styles {
            if let date = try? style.parse(raw) {
                return Int(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }
}
