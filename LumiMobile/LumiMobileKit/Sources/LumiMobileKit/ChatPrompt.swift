import Foundation

/// Faz 3 etkileşimli prompt wire modeli — LumiKit `ChatPrompt`'un decode-yönlü telefon kopyası.
public enum ChatPromptKind: String, Sendable, Equatable { case approval, question }
public enum ChatPromptState: String, Sendable, Equatable { case pending, resolved, cancelled }

public struct ChatPromptOption: Sendable, Equatable {
    public let id: String
    public let label: String
    public let description: String?
    public init(id: String, label: String, description: String?) {
        self.id = id; self.label = label; self.description = description
    }
    static func decode(_ d: [String: Any]) -> ChatPromptOption? {
        guard let id = d["id"] as? String, let label = d["label"] as? String else { return nil }
        return ChatPromptOption(id: id, label: label, description: d["description"] as? String)
    }
}

public struct ChatPrompt: Sendable, Equatable {
    public let itemId: String
    public let revision: Int
    public let kind: ChatPromptKind
    public let title: String
    public let detail: String?
    public let options: [ChatPromptOption]
    public let state: ChatPromptState
    public let selectedOptionId: String?

    public init(itemId: String, revision: Int, kind: ChatPromptKind, title: String, detail: String?,
                options: [ChatPromptOption], state: ChatPromptState, selectedOptionId: String?) {
        self.itemId = itemId; self.revision = revision; self.kind = kind; self.title = title
        self.detail = detail; self.options = options; self.state = state
        self.selectedOptionId = selectedOptionId
    }

    static func decode(_ d: [String: Any]) -> ChatPrompt? {
        guard let itemId = d["itemId"] as? String, let revision = d["revision"] as? Int,
              let kind = (d["kind"] as? String).flatMap(ChatPromptKind.init(rawValue:)),
              let title = d["title"] as? String,
              let state = (d["state"] as? String).flatMap(ChatPromptState.init(rawValue:)) else { return nil }
        let options = (d["options"] as? [[String: Any]])?.compactMap(ChatPromptOption.decode) ?? []
        return ChatPrompt(itemId: itemId, revision: revision, kind: kind, title: title,
                          detail: d["detail"] as? String, options: options, state: state,
                          selectedOptionId: d["selectedOptionId"] as? String)
    }
}
