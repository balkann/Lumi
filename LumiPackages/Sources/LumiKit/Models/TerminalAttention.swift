import Foundation

/// Başlığın "buraya bak" vurgusu (karar 77, Orca paritesi).
///
/// Orca'da seçili OLMAYAN bir sekme çalışmayı bitirip soru sorduğunda ya da
/// turn'ünü kapattığında sekmenin başlığı sarıya döner. Lumi'de sekme başlığı
/// yok; karşılığı terminal kartının kendi başlığı ve Projects panelindeki ajan
/// satırının başlığıdır. Kural view'sız ve TEK yerdedir ki iki yüzey zamanla
/// ayrışmasın.
public enum TerminalAttention {
    /// - `waitingUnseen`: turn kapandığında terminal odakta değildi. Odağı
    ///   kazanınca durum makinesi `waitingFocused`'a geçer ve vurgu kendiliğinden
    ///   düşer — "gördüm" bilgisi zaten orada tutulur, ayrıca saklanmaz.
    /// - Karar bekleme ayrı bir sinyaldir (durum `working` kalır): seçili
    ///   terminalde kullanıcı promptu zaten ekranda görür, vurgulanmaz.
    public static func isNeeded(
        status: TerminalStatus,
        isAwaitingDecision: Bool,
        isSelected: Bool
    ) -> Bool {
        if isAwaitingDecision { return !isSelected }
        return status == .waitingUnseen
    }
}
