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

public struct ChatPrompt: Sendable, Equatable {
    public var itemId: String
    public var revision: Int
    public var kind: ChatPromptKind
    public var title: String
    public var detail: String?
    public var options: [ChatPromptOption]
    public var state: ChatPromptState
    public var selectedOptionId: String?

    public init(itemId: String, revision: Int, kind: ChatPromptKind, title: String,
                detail: String?, options: [ChatPromptOption], state: ChatPromptState,
                selectedOptionId: String?) {
        self.itemId = itemId; self.revision = revision; self.kind = kind; self.title = title
        self.detail = detail; self.options = options; self.state = state
        self.selectedOptionId = selectedOptionId
    }

    public func toDict() -> [String: Any] {
        [
            "itemId": itemId, "revision": revision, "kind": kind.rawValue, "title": title,
            "detail": detail.map { $0 as Any } ?? NSNull(),
            "options": options.map { $0.toDict() },
            "state": state.rawValue,
            "selectedOptionId": selectedOptionId.map { $0 as Any } ?? NSNull(),
        ]
    }
}
