import Foundation

/// LumiKit `ChatTurnStatus`'un birebir telefon kopyası (decode yönü). Wire alanları:
/// working / startedAtMs / tool. sessionId frame zarfında taşınır.
public struct ChatTurnStatus: Sendable, Equatable {
    public let working: Bool
    public let startedAtMs: Int?
    public let tool: String?

    public init(working: Bool, startedAtMs: Int?, tool: String?) {
        self.working = working
        self.startedAtMs = startedAtMs
        self.tool = tool
    }

    public static let idle = ChatTurnStatus(working: false, startedAtMs: nil, tool: nil)

    static func decode(_ dict: [String: Any]) -> ChatTurnStatus {
        ChatTurnStatus(
            working: dict["working"] as? Bool ?? false,
            startedAtMs: dict["startedAtMs"] as? Int,
            tool: dict["tool"] as? String
        )
    }
}
