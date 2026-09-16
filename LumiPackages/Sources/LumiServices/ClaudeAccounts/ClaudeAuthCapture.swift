import Foundation
import LumiKit

/// Login sonrası yakalanan kimlik (karar 56) — saf ayrıştırma, I/O yok.
///
/// Kaynak sırası Orca'nınkiyle aynı: `claude auth status --json` → `.claude.json`
/// içindeki `oauthAccount` → credentials JSON'undaki `claudeAiOauth`. Biri
/// eksikse diğerine düşülür; e-posta hiçbirinden çıkmıyorsa hesap KAYDEDİLMEZ
/// (kimliksiz bir satır kullanıcıya hangi hesap olduğunu söyleyemez).
struct ClaudeIdentity: Sendable, Equatable {
    var email: String?
    var organizationUUID: String?
    var organizationName: String?

    static func resolve(
        statusJSON: String?,
        oauthAccountJSON: String?,
        credentialsJSON: String?
    ) -> ClaudeIdentity {
        let status = object(from: statusJSON)
        let oauth = object(from: oauthAccountJSON)
        let credentialOauth = object(from: credentialsJSON)?["claudeAiOauth"] as? [String: Any]
        return ClaudeIdentity(
            email: string(status, "email")
                ?? string(oauth, "emailAddress")
                ?? string(oauth, "email")
                ?? string(credentialOauth, "email"),
            organizationUUID: string(status, "organizationUuid")
                ?? string(status, "organizationId")
                ?? string(oauth, "organizationUuid")
                ?? string(oauth, "organizationId"),
            organizationName: string(status, "organizationName")
                ?? string(oauth, "organizationName")
        )
    }

    /// Kimlik bilgisinin gerçekten bir OAuth bloğu taşıyıp taşımadığı: boş ya
    /// da bozuk bir blob'u yüzeye materialize etmek kullanıcıyı sessizce
    /// oturumdan düşürürdü.
    static func isValidCredentials(_ credentialsJSON: String?) -> Bool {
        guard let oauth = object(from: credentialsJSON)?["claudeAiOauth"] as? [String: Any] else {
            return false
        }
        let token = (oauth["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(token ?? "").isEmpty
    }

    private static func object(from json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func string(_ object: [String: Any]?, _ key: String) -> String? {
        guard let value = (object?[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
