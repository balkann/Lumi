import Foundation
import LumiKit

enum CodexAccountCodec {
    static func decodeList(_ value: Any?) -> [CodexAccount] {
        guard let values = value as? [Any] else { return [] }
        var seen = Set<String>()
        return values.compactMap { value in
            guard let raw = value as? [String: Any],
                  let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  UUID(uuidString: id) != nil,
                  let email = (raw["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty, seen.insert(id).inserted else { return nil }
            let created = date(raw["createdAt"]) ?? Date(timeIntervalSince1970: 0)
            return CodexAccount(
                id: id,
                email: email,
                workspaceName: nonEmpty(raw["workspaceName"] as? String),
                createdAt: created,
                updatedAt: date(raw["updatedAt"]) ?? created,
                lastAuthenticatedAt: date(raw["lastAuthenticatedAt"]) ?? created
            )
        }
    }

    static func overlayList(_ accounts: [CodexAccount]) -> [[String: Any]] {
        accounts.map { account in
            var value: [String: Any] = [
                "id": account.id,
                "email": account.email,
                "createdAt": account.createdAt.timeIntervalSince1970,
                "updatedAt": account.updatedAt.timeIntervalSince1970,
                "lastAuthenticatedAt": account.lastAuthenticatedAt.timeIntervalSince1970,
            ]
            value["workspaceName"] = account.workspaceName
            return value
        }
    }

    static func decodeSelection(_ value: Any?, accounts: [CodexAccount]) -> CodexAccountSelection {
        guard let id = value as? String, accounts.contains(where: { $0.id == id }) else {
            return .systemDefault
        }
        return .account(id)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = JSONValue.double(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
