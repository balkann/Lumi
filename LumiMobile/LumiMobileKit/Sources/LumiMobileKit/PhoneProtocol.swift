import Foundation

/// Relay'den gelebilecek mesajlar (telefon rolü için, terminal-ayna protokolü).
public enum ServerMessage: Sendable, Equatable {
    case welcome(Welcome)
    case commandResult(CommandResult)
    case pong
    // Terminal-mirror mesajları
    case sessions([SessionMeta])
    case scrollback(TerminalChunk)
    case data(TerminalChunk)
    // Telefondan yeni oturum için repo listesi
    case repos([Repo])
}

public enum CommandAction: Sendable, Equatable {
    case sendText(sessionId: String, text: String)
    case pressKey(sessionId: String, key: String)
    case startSession(repoPath: String, personaId: String?, prompt: String)
    case getHistory(sessionId: String)
    case deleteSession(sessionId: String)
    case setModel(sessionId: String, model: String)
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
        case "command_result": return decodePayload(CommandResult.self).map(ServerMessage.commandResult)
        case "pong": return .pong
        case "sessions":
            struct SessionsPayload: Decodable { let sessions: [SessionMeta] }
            return decodePayload(SessionsPayload.self).map { ServerMessage.sessions($0.sessions) }
        case "scrollback": return decodeTerminalChunk(payload).map(ServerMessage.scrollback)
        case "data": return decodeTerminalChunk(payload).map(ServerMessage.data)
        case "repos":
            struct ReposPayload: Decodable { let repos: [Repo] }
            return decodePayload(ReposPayload.self).map { ServerMessage.repos($0.repos) }
        default: return nil
        }
    }

    // MARK: Terminal-mirror decoders

    static func decodeTerminalChunk(_ payload: [String: Any]) -> TerminalChunk? {
        guard let sessionId = payload["sessionId"] as? String,
              let seq = payload["seq"] as? Int,
              let b64 = payload["data"] as? String,
              let bytes = Data(base64Encoded: b64) else { return nil }
        return TerminalChunk(
            sessionId: sessionId,
            seq: seq,
            cols: payload["cols"] as? Int,
            rows: payload["rows"] as? Int,
            bytes: bytes
        )
    }

    // MARK: Terminal-mirror encoders

    public static func subscribeFrame(sessionId: String) -> String {
        frame(type: "subscribe", payload: ["sessionId": sessionId])
    }

    public static func unsubscribeFrame(sessionId: String) -> String {
        frame(type: "unsubscribe", payload: ["sessionId": sessionId])
    }

    public static func inputFrame(sessionId: String, data: Data) -> String {
        frame(type: "input", payload: [
            "sessionId": sessionId,
            "data": data.base64EncodedString()
        ])
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

    public static func unregisterPushFrame(deviceToken: String) -> String {
        frame(type: "unregister_push", payload: ["deviceToken": deviceToken])
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
        case .deleteSession(let sessionId):
            payload["action"] = "delete_session"
            payload["sessionId"] = sessionId
        case .setModel(let sessionId, let model):
            payload["action"] = "set_model"
            payload["sessionId"] = sessionId
            payload["model"] = model
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
