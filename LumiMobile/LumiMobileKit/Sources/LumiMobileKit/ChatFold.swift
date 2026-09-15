import Foundation

/// Katlanmış turn: bir "sahip" mesaj + ona ait tool-only aktivite mesajları.
public struct FoldedTurn: Identifiable, Sendable, Equatable {
    public let id: String
    public let message: ChatMessage
    public let toolActivity: [ChatMessage]
}

/// tool-only mesajları (yalnız tool-call/tool-result blokları) önceki metinli
/// turn'e katlar. Öncesinde sahip yoksa kendi turn'ü olur (orca fold alt kümesi).
public func foldChatMessages(_ messages: [ChatMessage]) -> [FoldedTurn] {
    var result: [FoldedTurn] = []
    for message in messages {
        if isToolOnly(message), var last = result.last {
            last = FoldedTurn(id: last.id, message: last.message,
                              toolActivity: last.toolActivity + [message])
            result[result.count - 1] = last
        } else {
            result.append(FoldedTurn(id: message.id, message: message, toolActivity: []))
        }
    }
    return result
}

private func isToolOnly(_ message: ChatMessage) -> Bool {
    guard !message.blocks.isEmpty else { return false }
    return message.blocks.allSatisfy { block in
        switch block {
        case .toolCall, .toolResult: return true
        default: return false
        }
    }
}
