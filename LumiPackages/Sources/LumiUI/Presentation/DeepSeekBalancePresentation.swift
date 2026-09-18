import Foundation
import LumiKit

/// Bakiye tutarlarının METİN hâli (karar 75) — model sunum metni taşımaz
/// (refactor 5.9 kuralı).
enum DeepSeekBalanceFormatter {
    /// Bilinen para birimlerinin simgesi; tanınmayan kod'un KENDİSİ yazılır
    /// ("SGD 4.20") — uydurma bir simge yerine doğru bilgi.
    private static let symbols = ["USD": "$", "CNY": "¥"]

    /// "$1.69" — tutar yoksa "—".
    static func amount(_ value: Decimal?, currency: String) -> String {
        guard let value else { return "—" }
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        let text = formatter.string(from: number) ?? number.stringValue
        guard let symbol = symbols[currency.uppercased()] else {
            return "\(currency.uppercased()) \(text)"
        }
        return "\(symbol)\(text)"
    }

    /// Topbar'daki kompakt etiket: birincil hesabın toplamı.
    static func compactLabel(_ balance: DeepSeekBalance?) -> String? {
        guard let account = balance?.primary else { return nil }
        return amount(account.total, currency: account.currency)
    }
}
