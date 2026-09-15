import Foundation

public enum ChatRole: String, Decodable, Sendable, Equatable {
    case user, assistant, tool, reasoning, system
}

public enum ChatBlock: Sendable, Equatable {
    case text(String, presentation: String?)
    case toolCall(name: String, inputPreview: String, state: String?)
    case toolResult(output: String, isError: Bool)
    case imageRef(path: String?, url: String?, alt: String?)
    case unknown

    static func decode(_ dict: [String: Any]) -> ChatBlock {
        switch dict["type"] as? String {
        case "text":
            return .text(dict["text"] as? String ?? "", presentation: dict["presentation"] as? String)
        case "tool-call":
            return .toolCall(name: dict["name"] as? String ?? "tool",
                             inputPreview: dict["inputPreview"] as? String ?? "",
                             state: dict["state"] as? String)
        case "tool-result":
            return .toolResult(output: dict["output"] as? String ?? "",
                               isError: dict["isError"] as? Bool ?? false)
        case "image-ref":
            return .imageRef(path: dict["path"] as? String, url: dict["url"] as? String,
                             alt: dict["alt"] as? String)
        default:
            return .unknown
        }
    }
}

public struct ChatMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let role: ChatRole
    public let blocks: [ChatBlock]
    public let timestampMs: Int?
    public let turnId: String?

    public init(id: String, role: ChatRole, blocks: [ChatBlock], timestampMs: Int?, turnId: String?) {
        self.id = id; self.role = role; self.blocks = blocks
        self.timestampMs = timestampMs; self.turnId = turnId
    }

    static func decode(_ dict: [String: Any]) -> ChatMessage? {
        guard let id = dict["id"] as? String,
              let role = ChatRole(rawValue: dict["role"] as? String ?? "") else { return nil }
        let blocks = (dict["blocks"] as? [[String: Any]])?.map(ChatBlock.decode) ?? []
        return ChatMessage(id: id, role: role, blocks: blocks,
                           timestampMs: dict["timestamp"] as? Int, turnId: dict["turnId"] as? String)
    }
}
