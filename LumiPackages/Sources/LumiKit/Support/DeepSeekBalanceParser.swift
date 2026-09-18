import Foundation

/// `/user/balance` gövdesini `DeepSeekBalance`'a çeviren SAF fonksiyon
/// (karar 75). Ağ/process yok → örnek gövdelerle unit-test edilir.
///
/// Şema (DeepSeek API dokümanı):
/// `{"is_available":true,"balance_infos":[{"currency":"USD",
///   "total_balance":"1.69","granted_balance":"0.00","topped_up_balance":"1.69"}]}`
public enum DeepSeekBalanceParser {
    /// Gövde tanınmazsa nil (çağıran hata fırlatır). `balance_infos` boş gelse
    /// bile yanıt geçerlidir: `is_available` tek başına anlam taşır.
    public static func parse(_ data: Data, now: Date = Date()) -> DeepSeekBalance? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isAvailable = JSONValue.bool(root["is_available"]) else {
            return nil
        }
        let entries = (root["balance_infos"] as? [[String: Any]]) ?? []
        return DeepSeekBalance(
            isAvailable: isAvailable,
            accounts: entries.compactMap(account(from:)),
            fetchedAt: now
        )
    }

    /// Para birimi olmayan satır atlanır (kimliği odur); tutarların hepsi
    /// çözülemese de satır korunur.
    private static func account(from entry: [String: Any]) -> DeepSeekBalance.Account? {
        guard let currency = (entry["currency"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !currency.isEmpty else {
            return nil
        }
        return DeepSeekBalance.Account(
            currency: currency.uppercased(),
            total: amount(entry["total_balance"]),
            granted: amount(entry["granted_balance"]),
            toppedUp: amount(entry["topped_up_balance"])
        )
    }

    /// Tutar metin gelir; sayı gönderen bir sürüme karşı ikisi de kabul edilir.
    /// `Decimal(string:)` locale'den bağımsızdır (nokta ayraç) — `Double` yolu
    /// parayı bozacağı için bilinçle kullanılmaz.
    static func amount(_ value: Any?) -> Decimal? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        }
        if let number = value as? NSNumber { return number.decimalValue }
        return nil
    }
}
