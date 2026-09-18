import Foundation

/// `GET api.deepseek.com/user/balance` yanıtının yapısal hâli (karar 75).
///
/// DeepSeek'in genel API'sinde YALNIZ bu uç vardır: harcama geçmişi, token
/// sayacı ya da limit/reset penceresi döndüren bir uç yoktur. Gösterge bu
/// yüzden yüzde/bar değil, bakiye satırları çizer.
///
/// Tutarlar yanıtta METİN olarak gelir (`"110.00"`); `Decimal`'e çevrilir —
/// `Double` para için yuvarlama hatası üretir. Çevrilemeyen değer `nil` kalır,
/// satır düşmez (design/05: parse hatası veriyi düşürmez).
public struct DeepSeekBalance: Sendable, Equatable {
    /// Tek para birimi için bakiye üçlüsü. DeepSeek dizi döndürür (CNY + USD
    /// hesapları ayrı gelebilir), o yüzden liste olarak taşınır.
    public struct Account: Sendable, Equatable, Identifiable {
        /// `USD` / `CNY` — ham kod; simge sunum katmanında eşlenir.
        public let currency: String
        /// Toplam kullanılabilir bakiye (hediye + yüklenen).
        public let total: Decimal?
        /// Süresi dolmamış hediye bakiye.
        public let granted: Decimal?
        /// Yüklenen bakiye.
        public let toppedUp: Decimal?

        public var id: String { currency }

        public init(currency: String, total: Decimal?, granted: Decimal?, toppedUp: Decimal?) {
            self.currency = currency
            self.total = total
            self.granted = granted
            self.toppedUp = toppedUp
        }
    }

    /// Sunucunun "bu bakiyeyle istek atılabilir mi" cevabı; tutarlardan
    /// TÜRETİLMEZ (hesap askıya alınmış olabilir).
    public let isAvailable: Bool
    public let accounts: [Account]
    public let fetchedAt: Date

    public init(isAvailable: Bool, accounts: [Account], fetchedAt: Date) {
        self.isAvailable = isAvailable
        self.accounts = accounts
        self.fetchedAt = fetchedAt
    }

    /// Topbar'ın gösterdiği hesap: ilk sıradaki (DeepSeek hesabın kendi para
    /// birimini başa koyar). Hiç hesap yoksa nil → gösterge "—" çizer.
    public var primary: Account? { accounts.first }
}
