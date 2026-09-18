import Foundation

/// Codex threads are identified by hook-reported `session_id` values. Unlike
/// Claude, a fresh ID cannot be injected at launch; it is learned at runtime.
public enum CodexSessionCommand {
    public static func resumeCommand(sessionID: String) -> String? {
        guard isSafe(sessionID) else { return nil }
        return "codex resume \(shellQuote(sessionID)) || codex"
    }

    public static func resumedSessionID(from command: String?) -> String? {
        guard let command else { return nil }
        let pattern = #"(?:^|\s)codex\s+resume\s+(['\"]?)([^\s'\"]+)\1(?:\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: command, range: NSRange(command.startIndex..., in: command)
              ),
              let range = Range(match.range(at: 2), in: command) else { return nil }
        let value = String(command[range])
        return isSafe(value) ? value : nil
    }

    public static func isSafe(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,511}$"#, options: .regularExpression) != nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
