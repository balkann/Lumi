import Foundation
import LumiKit

/// POSIX tek-tırnak quoting: ' → '\'' .
func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Telefondan gelen komutları uygular (spec §4.2 RemoteCommandHandler).
/// Cevap her zaman command_result payload'ıdır: {commandId, ok, error?}.
@MainActor
final class RemoteCommandHandler {
    private let terminal: any TerminalServicing

    init(terminal: any TerminalServicing) {
        self.terminal = terminal
    }

    func handle(_ payload: [String: Any]) async -> sending [String: Any] {
        let commandId: Any = (payload["commandId"] as? String) ?? NSNull()
        switch payload["action"] as? String {
        case "send_text":
            return result(commandId, run: {
                let id = try self.session(from: payload)
                let text = payload["text"] as? String ?? ""
                try self.terminal.write(id: id, text: text + "\r")
            })
        case "press_key":
            guard let sequence = keySequence(for: payload["key"] as? String ?? "") else {
                return ["commandId": commandId, "ok": false, "error": "unknown_key"]
            }
            return result(commandId, run: {
                let id = try self.session(from: payload)
                try self.terminal.write(id: id, text: sequence)
            })
        case "delete_session":
            return result(commandId, run: {
                let id = try self.session(from: payload)
                try self.terminal.kill(id: id)
            })
        case "start_session":
            return await startSession(payload, commandId: commandId)
        case "set_model":
            let model = payload["model"] as? String ?? ""
            guard Self.allowedModels.contains(model) else {
                return ["commandId": commandId, "ok": false, "error": "unknown_model"]
            }
            return result(commandId, run: {
                let id = try self.session(from: payload)
                try self.terminal.write(id: id, text: "/model \(model)\r")
            })
        default:
            return ["commandId": commandId, "ok": false, "error": "unknown_action"]
        }
    }

    private func startSession(_ payload: [String: Any], commandId: Any) async -> sending [String: Any] {
        let repoPath = payload["repoPath"] as? String ?? ""
        let prompt = payload["prompt"] as? String ?? ""
        do {
            let command = prompt.isEmpty ? "claude" : "claude " + shellQuoted(prompt)
            _ = try terminal.spawn(repoPath: repoPath, task: nil, command: command)
            return ["commandId": commandId, "ok": true]
        } catch {
            return ["commandId": commandId, "ok": false, "error": "\(error)"]
        }
    }

    private func session(from payload: [String: Any]) throws -> TerminalID {
        guard let raw = payload["sessionId"] as? String,
              let uuid = UUID(uuidString: raw),
              terminal.terminals.contains(where: { $0.id.raw == uuid })
        else { throw CommandError.sessionNotFound }
        return TerminalID(raw: uuid)
    }

    private func result(_ commandId: Any, run: () throws -> Void) -> sending [String: Any] {
        do {
            try run()
            return ["commandId": commandId, "ok": true]
        } catch CommandError.sessionNotFound {
            return ["commandId": commandId, "ok": false, "error": "session_not_found"]
        } catch {
            return ["commandId": commandId, "ok": false, "error": "\(error)"]
        }
    }

    private static let allowedModels: Set<String> = ["opus", "sonnet", "haiku", "default"]

    private enum CommandError: Error { case sessionNotFound }
}
