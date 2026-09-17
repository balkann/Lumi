import Foundation

/// Faz 2 canlı turn-status wire modeli. Değişmez pattern: LumiKit'te tanımlanır,
/// LumiMobileKit'e birebir kopyalanır (bkz. `ChatMessage`). `sessionId` frame
/// zarfında taşınır, modelin parçası değildir.
public struct ChatTurnStatus: Sendable, Equatable {
    public var working: Bool
    public var startedAtMs: Int?      // tur başı (epoch ms); working=false ise nil
    public var tool: String?          // o an koşan lider araç adı; yoksa nil
    public var streamingText: String? // canlı in-flight assistant metni (Faz 2); yoksa nil

    public init(working: Bool, startedAtMs: Int?, tool: String?, streamingText: String? = nil) {
        self.working = working
        self.startedAtMs = startedAtMs
        self.tool = tool
        self.streamingText = streamingText
    }

    public static let idle = ChatTurnStatus(working: false, startedAtMs: nil, tool: nil)

    public func toDict() -> [String: Any] {
        [
            "working": working,
            "startedAtMs": startedAtMs.map { $0 as Any } ?? NSNull(),
            "tool": tool.map { $0 as Any } ?? NSNull(),
            "streamingText": streamingText.map { $0 as Any } ?? NSNull(),
        ]
    }

    public static func decode(_ dict: [String: Any]) -> ChatTurnStatus {
        ChatTurnStatus(
            working: dict["working"] as? Bool ?? false,
            startedAtMs: dict["startedAtMs"] as? Int,
            tool: dict["tool"] as? String,
            streamingText: dict["streamingText"] as? String
        )
    }
}
