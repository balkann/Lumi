import Foundation

/// Faz 3 etkileşimli prompt wire modeli (orca paritesi). LumiKit'te tanımlanır,
/// LumiMobileKit'e birebir kopyalanır. `sessionId` frame zarfında taşınır.
public enum ChatPromptKind: String, Sendable, Equatable { case approval, question }
public enum ChatPromptState: String, Sendable, Equatable { case pending, resolved, cancelled }

public struct ChatPromptOption: Sendable, Equatable {
    public let id: String
    public let label: String
    public let description: String?
    public init(id: String, label: String, description: String?) {
        self.id = id; self.label = label; self.description = description
    }
    public func toDict() -> [String: Any] {
        ["id": id, "label": label, "description": description.map { $0 as Any } ?? NSNull()]
    }
}

/// Faz 3.1: gruplu çok-soru için tek bir soru (orca `AskQuestion`).
public struct ChatPromptQuestion: Sendable, Equatable {
    public var id: String
    public var question: String
    public var header: String?
    public var multiSelect: Bool
    public var allowOther: Bool
    public var options: [ChatPromptOption]
    public init(id: String, question: String, header: String?, multiSelect: Bool,
                allowOther: Bool, options: [ChatPromptOption]) {
        self.id = id; self.question = question; self.header = header
        self.multiSelect = multiSelect; self.allowOther = allowOther; self.options = options
    }
    public func toDict() -> [String: Any] {
        [
            "id": id, "question": question,
            "header": header.map { $0 as Any } ?? NSNull(),
            "multiSelect": multiSelect, "allowOther": allowOther,
            "options": options.map { $0.toDict() },
        ]
    }
}

public struct ChatPrompt: Sendable, Equatable {
    public var itemId: String
    public var revision: Int
    public var kind: ChatPromptKind
    public var title: String
    public var detail: String?
    public var options: [ChatPromptOption]
    public var state: ChatPromptState
    public var selectedOptionId: String?
    // Faz 3.1 additive (Faz 3.0 çağrı yerleri default'la derlenir):
    public var multiSelect: Bool          // tek-soru çoklu-seçim
    public var allowOther: Bool           // tek-soru free-text
    public var questions: [ChatPromptQuestion]  // gruplu (>1); tek-soru/approval'da boş

    public init(itemId: String, revision: Int, kind: ChatPromptKind, title: String,
                detail: String?, options: [ChatPromptOption], state: ChatPromptState,
                selectedOptionId: String?, multiSelect: Bool = false,
                allowOther: Bool = false, questions: [ChatPromptQuestion] = []) {
        self.itemId = itemId; self.revision = revision; self.kind = kind; self.title = title
        self.detail = detail; self.options = options; self.state = state
        self.selectedOptionId = selectedOptionId
        self.multiSelect = multiSelect; self.allowOther = allowOther; self.questions = questions
    }

    public func toDict() -> [String: Any] {
        [
            "itemId": itemId, "revision": revision, "kind": kind.rawValue, "title": title,
            "detail": detail.map { $0 as Any } ?? NSNull(),
            "options": options.map { $0.toDict() },
            "state": state.rawValue,
            "selectedOptionId": selectedOptionId.map { $0 as Any } ?? NSNull(),
            "multiSelect": multiSelect, "allowOther": allowOther,
            "questions": questions.map { $0.toDict() },
        ]
    }
}
