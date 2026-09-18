import Foundation

/// Claude limit pencerelerinin UZUNLUĞU (karar 74).
///
/// Anthropic'in usage yanıtı reset ANINI verir, pencere boyunu ayrı bir alanda
/// vermez — Codex'in `windowDurationMins`'inin karşılığı yoktur. Boy yine de
/// yanıtın KENDİ sözlüğünden okunur: üst düzey alanların adları `five_hour` ve
/// `seven_day`'dir, `limits` dizisindeki `kind` değerleri (`session`,
/// `weekly_all`, `weekly_scoped`) bu iki pencereye eşlenir. Yani buradaki
/// sabitler uydurma değil, kaynağın adlandırmasının kod hâlidir.
///
/// Tanınmayan satır (`.other`) için nil: bilinmeyen bir limitin penceresi 5
/// saat VARSAYILMAZ, o satırda tempo çizgisi çizilmez.
public enum ClaudeUsageWindows {
    /// `five_hour` — oturum penceresi.
    public static let session: TimeInterval = 5 * 60 * 60
    /// `seven_day` — haftalık pencereler (toplam ve model-özel).
    public static let weekly: TimeInterval = 7 * 24 * 60 * 60

    public static func duration(for kind: UsageLimit.Kind) -> TimeInterval? {
        switch kind {
        case .session: return session
        case .weeklyAll, .weeklyModel: return weekly
        case .other: return nil
        }
    }
}
