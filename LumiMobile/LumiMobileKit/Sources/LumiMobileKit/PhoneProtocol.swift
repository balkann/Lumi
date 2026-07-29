import Foundation

/// Relay'den gelebilecek mesajlar (telefon rolü için).
public enum ServerMessage: Sendable, Equatable {
    case welcome(Welcome)
    case snapshot(Snapshot)
    case event(RemoteEvent)
    case commandResult(CommandResult)
    case pong
}

public enum CommandAction: Sendable, Equatable {
    case sendText(sessionId: String, text: String)
    case pressKey(sessionId: String, key: String)
    case startSession(repoPath: String, personaId: String?, prompt: String)
    case getHistory(sessionId: String)
}

public struct OutgoingCommand: Sendable, Equatable {
    public let commandId: String
    public let action: CommandAction

    public init(commandId: String, action: CommandAction) {
        self.commandId = commandId
        self.action = action
    }
}

/// Zarf codec'i — docs/spec/50-remote-protocol.md ile birebir.
/// Gelen taraf toleranslıdır: bilinmeyen tip/kind/itemType nil döner, akış kırılmaz.
public enum PhoneProtocol {
    public static let version = 1

    // MARK: Gelen

    public static func decodeServerMessage(_ text: String) -> ServerMessage? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["v"] as? Int == version,
              let type = dict["type"] as? String,
              let payload = dict["payload"] as? [String: Any] else { return nil }

        func decodePayload<T: Decodable>(_: T.Type) -> T? {
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return try? JSONDecoder().decode(T.self, from: payloadData)
        }

        switch type {
        case "welcome": return decodePayload(Welcome.self).map(ServerMessage.welcome)
        case "snapshot": return decodePayload(Snapshot.self).map(ServerMessage.snapshot)
        case "event": return decodeEvent(payload).map(ServerMessage.event)
        case "command_result": return decodePayload(CommandResult.self).map(ServerMessage.commandResult)
        case "pong": return .pong
        default: return nil
        }
    }

    static func decodeEvent(_ payload: [String: Any]) -> RemoteEvent? {
        guard let kind = payload["kind"] as? String,
              let sessionId = payload["sessionId"] as? String else { return nil }
        switch kind {
        case "status_change":
            guard let rawStatus = payload["status"] as? String else { return nil }
            return .statusChange(
                sessionId: sessionId,
                status: SessionStatus(rawValue: rawStatus) ?? .idle,
                repoName: payload["repoName"] as? String ?? "",
                summary: payload["summary"] as? String
            )
        case "transcript":
            guard let item = payload["item"] as? [String: Any],
                  let feedItem = decodeFeedItem(item) else { return nil }
            return .transcript(sessionId: sessionId, item: feedItem)
        case "history":
            guard let rawItems = payload["items"] as? [[String: Any]] else { return nil }
            let items = rawItems.compactMap(decodeFeedItem)
            return .history(sessionId: sessionId, items: items)
        default:
            return nil
        }
    }

    static func decodeFeedItem(_ item: [String: Any]) -> FeedItem? {
        switch item["itemType"] as? String {
        case "assistant_text":
            guard let text = item["text"] as? String else { return nil }
            return .assistantText(text)
        case "tool_use":
            guard let tool = item["tool"] as? String else { return nil }
            return .toolUse(tool: tool, summary: item["summary"] as? String ?? "")
        case "question":
            guard let raw = item["questions"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let questions = try? JSONDecoder().decode([Question].self, from: data) else { return nil }
            return .question(questions)
        case "turn_done":
            return .turnDone
        default:
            return nil
        }
    }

    // MARK: Giden

    public static func helloFrame(token: String) -> String {
        frame(type: "hello", payload: ["role": "phone", "token": token])
    }

    public static func pingFrame() -> String {
        frame(type: "ping", payload: [:])
    }

    public static func registerPushFrame(deviceToken: String) -> String {
        frame(type: "register_push", payload: ["deviceToken": deviceToken])
    }

    public static func commandFrame(_ command: OutgoingCommand) -> String {
        var payload: [String: Any] = ["commandId": command.commandId]
        switch command.action {
        case .sendText(let sessionId, let text):
            payload["action"] = "send_text"
            payload["sessionId"] = sessionId
            payload["text"] = text
        case .pressKey(let sessionId, let key):
            payload["action"] = "press_key"
            payload["sessionId"] = sessionId
            payload["key"] = key
        case .startSession(let repoPath, let personaId, let prompt):
            payload["action"] = "start_session"
            payload["repoPath"] = repoPath
            payload["prompt"] = prompt
            if let personaId { payload["personaId"] = personaId }
        case .getHistory(let sessionId):
            payload["action"] = "get_history"
            payload["sessionId"] = sessionId
        }
        return frame(type: "command", payload: payload)
    }

    private static func frame(type: String, payload: [String: Any]) -> String {
        let dict: [String: Any] = ["v": version, "type": type, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
