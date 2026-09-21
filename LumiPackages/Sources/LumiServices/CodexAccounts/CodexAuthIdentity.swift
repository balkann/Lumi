import Foundation

struct CodexAuthIdentity: Sendable, Equatable {
    let email: String?
    let workspaceName: String?

    static func read(from data: Data) -> CodexAuthIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if nonEmpty(root["OPENAI_API_KEY"] as? String) != nil { return nil }
        guard let tokens = root["tokens"] as? [String: Any],
              let rawToken = (tokens["id_token"] ?? tokens["idToken"]) as? String,
              let payload = jwtPayload(rawToken) else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        return CodexAuthIdentity(
            email: nonEmpty(payload["email"] as? String) ?? nonEmpty(profile?["email"] as? String),
            workspaceName: nonEmpty(auth?["workspace_name"] as? String)
                ?? nonEmpty(profile?["workspace_name"] as? String)
        )
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
