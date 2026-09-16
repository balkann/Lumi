import Foundation
import LumiKit

/// `config.json` ▸ `claudeAccounts` / `activeClaudeAccountId` (karar 56).
///
/// Additive (karar 9): anahtar yoksa liste boş, seçim `systemDefault`'tur.
/// Kimlik bilgisi taşımaz — bkz. `ClaudeAccount`. Zaman damgaları epoch
/// saniyesidir; okuma lenient'tır, eksik/bozuk kayıt sessizce elenir.
enum ClaudeAccountCodec {
    static func decodeList(_ value: Any?) -> [ClaudeAccount] {
        guard let values = value as? [Any] else { return [] }
        var seen = Set<String>()
        return values.compactMap { raw in
            guard let raw = raw as? [String: Any],
                  let id = (raw["id"] as? String)?.trimmed, !id.isEmpty,
                  let email = (raw["email"] as? String)?.trimmed, !email.isEmpty,
                  seen.insert(id).inserted else { return nil }
            let created = date(raw["createdAt"]) ?? Date(timeIntervalSince1970: 0)
            return ClaudeAccount(
                id: id,
                email: email,
                organizationUUID: (raw["organizationUuid"] as? String)?.nonEmpty,
                organizationName: (raw["organizationName"] as? String)?.nonEmpty,
                createdAt: created,
                updatedAt: date(raw["updatedAt"]) ?? created,
                lastAuthenticatedAt: date(raw["lastAuthenticatedAt"]) ?? created
            )
        }
    }

    static func overlayList(_ accounts: [ClaudeAccount]) -> [[String: Any]] {
        accounts.map { account in
            var entry: [String: Any] = [
                "id": account.id,
                "email": account.email,
                "createdAt": account.createdAt.timeIntervalSince1970,
                "updatedAt": account.updatedAt.timeIntervalSince1970,
                "lastAuthenticatedAt": account.lastAuthenticatedAt.timeIntervalSince1970,
            ]
            entry["organizationUuid"] = account.organizationUUID
            entry["organizationName"] = account.organizationName
            return entry
        }
    }

    /// Seçim yalnız VAR OLAN bir hesabı gösterebilir; silinmiş bir id sessizce
    /// sistem varsayılanına düşer (Orca'nın `pruneInvalidClaudeRuntimeSelection`
    /// karşılığı).
    static func decodeSelection(_ value: Any?, accounts: [ClaudeAccount]) -> ClaudeAccountSelection {
        guard let id = (value as? String)?.trimmed, accounts.contains(where: { $0.id == id }) else {
            return .systemDefault
        }
        return .account(id)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = JSONValue.double(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}
