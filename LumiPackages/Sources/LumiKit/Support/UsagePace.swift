import Foundation

/// Kullanımın tempo çizgisine (pace marker, karar 74) göre konumu — karar 85.
///
/// `UsageLevel` MUTLAK tüketimi banda ayırır (%50 / %80). Bu tip ise aynı sayıyı
/// pencerenin geçen kısmıyla kıyaslar: asıl soru "ne kadar harcadım" değil,
/// "saatten hızlı mı harcıyorum"dur. %30, pencerenin %5'indeyken alarm,
/// %90'ındayken rahatlıktır.
///
/// Aritmetik SAF ve view'sızdır; rampanın renkleri LumiUI'daki presenter'ın işi
/// (`UsagePace.color`, `UsageTint`). Böylece tooltip'in yazdığı puan farkıyla
/// barın rengi aynı sayıdan beslenir ve ikisi ayrışamaz.
public struct UsagePace: Sendable, Equatable {
    /// Çizginin çevresinde rengin DEĞİŞMEDİĞİ bant (puan): tempoda giden bir
    /// pencere birkaç puanlık salınımla renk titretmemeli.
    public static let tolerance = 5
    /// Tolerans kenarından tam soğuk uca (buz mavisi) kadarki mesafe (puan).
    public static let coolSpan = 25
    /// Tolerans kenarından kritik uca kadarki mesafe (puan). Sıcak taraf
    /// bilerek daha geniştir: geride kalmak haberdir, öne geçmek uyarıdır —
    /// uyarıya geçmek için daha çok kanıt istenir.
    public static let warmSpan = 40

    public let percentUsed: Int
    /// Pencerenin geçen kısmı, yüzdeyle aynı ölçeğe (0–100 puan) yuvarlanmış.
    public let elapsedPoints: Int

    /// Yüzde ya da pencere süresi bilinmiyorsa tempo YOKTUR (nil) — uydurulmaz
    /// (karar 74'teki veri kapısının aynısı).
    public init?(percentUsed: Int?, elapsedFraction: Double?) {
        guard let percentUsed, let elapsedFraction else { return nil }
        self.percentUsed = percentUsed
        self.elapsedPoints = Int((min(1, max(0, elapsedFraction)) * 100).rounded())
    }

    /// Harcananın tempodan farkı (puan): eksi = geride, artı = önde.
    public var deltaPoints: Int { percentUsed - elapsedPoints }

    /// Renk rampasındaki konum: -1 (tam soğuk) … 0 (tempoda) … +1 (kritik).
    public var toneStop: Double {
        // Limit dolduysa tempo teselli değildir: rampa tavana oturur.
        guard percentUsed < 100 else { return 1 }
        let distance = abs(deltaPoints) - Self.tolerance
        guard distance > 0 else { return 0 }
        let span = deltaPoints > 0 ? Self.warmSpan : Self.coolSpan
        let stop = min(1, Double(distance) / Double(span))
        return deltaPoints > 0 ? stop : -stop
    }
}
