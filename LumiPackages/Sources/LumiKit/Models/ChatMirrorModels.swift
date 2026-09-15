import Foundation

/// orca `native-chat-types.ts` paritesi (Faz 1 alt kümesi). Wire modeli:
/// `RemoteProtocol` bunları `[String: Any]` payload'a çevirir, telefon decode eder.
public enum ChatRole: String, Sendable, Equatable {
    case user, assistant, tool, reasoning, system
}

/// orca `NativeChatSubagentEntry` paritesi — bir spawn grubundaki alt ajan.
public struct ChatSubagentEntry: Sendable, Equatable {
    public let id: String
    public let label: String
    public let state: String
    public let tokens: Int?
    public let startedAt: Int?
    public let settledAt: Int?

    public init(id: String, label: String, state: String,
                tokens: Int? = nil, startedAt: Int? = nil, settledAt: Int? = nil) {
        self.id = id; self.label = label; self.state = state
        self.tokens = tokens; self.startedAt = startedAt; self.settledAt = settledAt
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["id": id, "label": label, "state": state]
        if let tokens { d["tokens"] = tokens }
        if let startedAt { d["startedAt"] = startedAt }
        if let settledAt { d["settledAt"] = settledAt }
        return d
    }
}

public enum ChatBlock: Sendable, Equatable {
    case text(String, presentation: String?)
    case toolCall(name: String, inputPreview: String, state: String?)
    case toolResult(output: String, isError: Bool)
    case imageRef(path: String?, url: String?, alt: String?)
    case subagentGroup(groupId: String, agents: [ChatSubagentEntry])

    func toDict() -> [String: Any] {
        switch self {
        case let .text(text, presentation):
            var d: [String: Any] = ["type": "text", "text": text]
            if let presentation { d["presentation"] = presentation }
            return d
        case let .toolCall(name, inputPreview, state):
            var d: [String: Any] = ["type": "tool-call", "name": name, "inputPreview": inputPreview]
            if let state { d["state"] = state }
            return d
        case let .toolResult(output, isError):
            return ["type": "tool-result", "output": output, "isError": isError]
        case let .imageRef(path, url, alt):
            var d: [String: Any] = ["type": "image-ref"]
            if let path { d["path"] = path }
            if let url { d["url"] = url }
            if let alt { d["alt"] = alt }
            return d
        case let .subagentGroup(groupId, agents):
            return ["type": "subagent-group", "groupId": groupId, "agents": agents.map { $0.toDict() }]
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
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestampMs = timestampMs
        self.turnId = turnId
    }

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "role": role.rawValue,
            "timestamp": timestampMs.map { $0 as Any } ?? NSNull(),
            "turnId": turnId.map { $0 as Any } ?? NSNull(),
            "blocks": blocks.map { $0.toDict() },
        ]
    }
}

/// Kaynak → RemoteService olayları: ilk snapshot, sonra append'ler.
public enum ChatMirrorEvent: Sendable, Equatable {
    case snapshot([ChatMessage])
    case append([ChatMessage])
}
