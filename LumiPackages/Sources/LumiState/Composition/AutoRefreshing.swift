import Foundation

/// Otomatik tazeleme döngüsünün (karar 20) tazeleyebileceği store'lar.
///
/// Döngü `UsageStore` listesine bağlıydı; DeepSeek bakiye göstergesi (karar 75)
/// aynı aralıkta tazelenmeli ama `UsageStore` DEĞİLDİR (pencere/yüzde değil,
/// para taşır). Ortak yüz bu tek metottur — döngü somut tipi bilmez (DIP).
///
/// Sözleşme: `refresh()` kapalı ya da çok yeni bir store'da sessizce no-op'tur;
/// kapı çağıranın değil store'un içindedir.
@MainActor
public protocol AutoRefreshing: AnyObject {
    func refresh() async
}

extension UsageStore: AutoRefreshing {}
extension DeepSeekBalanceStore: AutoRefreshing {}
