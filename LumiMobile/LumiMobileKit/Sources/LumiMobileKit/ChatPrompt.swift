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

/// Faz 3.1: gruplu çok-soru (orca `AskQuestion`) — telefon kopyası.
public struct ChatPromptQuestion: Sendable, Equatable {
    public let id: String
    public let question: String
    public let header: String?
    public let multiSelect: Bool
    public let allowOther: Bool
    public let options: [ChatPromptOption]
    public init(id: String, question: String, header: String?, multiSelect: Bool,
                allowOther: Bool, options: [ChatPromptOption]) {
        self.id = id; self.question = question; self.header = header
        self.multiSelect = multiSelect; self.allowOther = allowOther; self.options = options
    }
    static func decode(_ d: [String: Any]) -> ChatPromptQuestion? {
        guard let id = d["id"] as? String, let question = d["question"] as? String else { return nil }
        let options = (d["options"] as? [[String: Any]])?.compactMap(ChatPromptOption.decode) ?? []
        return ChatPromptQuestion(id: id, question: question, header: d["header"] as? String,
                                  multiSelect: d["multiSelect"] as? Bool ?? false,
                                  allowOther: d["allowOther"] as? Bool ?? false, options: options)
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
    public let multiSelect: Bool
    public let allowOther: Bool
    public let questions: [ChatPromptQuestion]

    public init(itemId: String, revision: Int, kind: ChatPromptKind, title: String, detail: String?,
                options: [ChatPromptOption], state: ChatPromptState, selectedOptionId: String?,
                multiSelect: Bool = false, allowOther: Bool = false, questions: [ChatPromptQuestion] = []) {
        self.itemId = itemId; self.revision = revision; self.kind = kind; self.title = title
        self.detail = detail; self.options = options; self.state = state
        self.selectedOptionId = selectedOptionId
        self.multiSelect = multiSelect; self.allowOther = allowOther; self.questions = questions
    }

    static func decode(_ d: [String: Any]) -> ChatPrompt? {
        guard let itemId = d["itemId"] as? String, let revision = d["revision"] as? Int,
              let kind = (d["kind"] as? String).flatMap(ChatPromptKind.init(rawValue:)),
              let title = d["title"] as? String,
              let state = (d["state"] as? String).flatMap(ChatPromptState.init(rawValue:)) else { return nil }
        let options = (d["options"] as? [[String: Any]])?.compactMap(ChatPromptOption.decode) ?? []
        let questions = (d["questions"] as? [[String: Any]])?.compactMap(ChatPromptQuestion.decode) ?? []
        return ChatPrompt(itemId: itemId, revision: revision, kind: kind, title: title,
                          detail: d["detail"] as? String, options: options, state: state,
                          selectedOptionId: d["selectedOptionId"] as? String,
                          multiSelect: d["multiSelect"] as? Bool ?? false,
                          allowOther: d["allowOther"] as? Bool ?? false, questions: questions)
    }
}
