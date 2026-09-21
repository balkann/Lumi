import Foundation
import LumiKit
import SwiftUI

/// Kullanım limitlerinin UI metinleri (refactor 5.9): model katmanı sunum
/// string'i taşımaz — `UsageLimit` yalnız kind + ham etiketi bilir.
extension UsageLimit {
    /// Tanınan türler normalize edilir, tanınmayan ham etiketi kullanır.
    var displayTitle: String {
        switch kind {
        case .session: return "5-hour session"
        case .weeklyAll: return "Weekly (all models)"
        case .weeklyModel(let name): return "Weekly (\(name))"
        case .other: return rawLabel
        }
    }
}

/// Uyarı seviyesi → renk (refactor 7.5): eşik mantığı LumiKit'te
/// (`UsageLevel`), tema eşlemesi burada. Model katmanı renk bilmez.
///
/// Bu MUTLAK bant artık yalnız YEDEKTİR (karar 85): pencerenin süresi
/// bilinmediği için tempo hesaplanamayan satırlarda kullanılır.
extension UsageLevel {
    var color: Color {
        switch self {
        case .normal: return Theme.success
        case .warning: return Theme.warning
        case .critical: return Theme.error
        }
    }
}

/// Tempo rampası (karar 85): renk, harcanan mutlak yüzdeyi değil, dolgunun
/// tempo çizgisine göre yerini söyler.
///
/// ```
///   -1 ───────────── 0 ───────── +0.5 ───────── +1
///   ice            success      warning       error
///   geride         tempoda      önde          kritik
/// ```
///
/// Çizginin ±`UsagePace.tolerance` puanlık çevresi düz yeşildir; dışına
/// çıkıldıkça renk sürekli (adım adım değil) kayar, çünkü sinyalin kendisi
/// süreklidir: "ne kadar geride" ile "ne kadar önde" derece meselesidir.
extension UsagePace {
    /// Sarının rampadaki yeri: uç değil, sıcak yarının ORTA durağı. Kırmızı
    /// yalnız uçta durur ki "kritik" seyrek ve inandırıcı kalsın.
    static let warningStop = 0.5

    var color: Color {
        let stop = toneStop
        if stop < 0 { return Theme.blend(Theme.Hex.success, Theme.Hex.ice, -stop) }
        if stop <= Self.warningStop {
            return Theme.blend(Theme.Hex.success, Theme.Hex.warning, stop / Self.warningStop)
        }
        return Theme.blend(
            Theme.Hex.warning,
            Theme.Hex.error,
            (stop - Self.warningStop) / (1 - Self.warningStop)
        )
    }

    /// "28 pt under pace" / "on pace" / "30 pt over pace" — rengin sözle
    /// karşılığı. Renk tek başına erişilebilir bir kanal değildir; bu metin
    /// tooltip'e ve VoiceOver etiketine girer.
    var verdict: String {
        switch deltaPoints {
        case 0: return "on pace"
        case ..<0: return "\(-deltaPoints) pt under pace"
        default: return "\(deltaPoints) pt over pace"
        }
    }

    /// Tooltip'in tam cümlesi.
    var summary: String { "Window \(elapsedPoints)% elapsed · \(verdict)" }
}

/// Bir kullanım penceresinin rengi — göstergenin TEK kapısı.
///
/// Topbar'daki kompakt yüzde ile popover'daki dolgu aynı yerden beslenir
/// (karar 85): topbar'a bar sığmadığı için tempo sinyali oraya yalnız renkle
/// ulaşabilir, ve iki yüzeyin farklı şey söylemesi kabul edilemez.
enum UsageTint {
    /// Tempo biliniyorsa rampadan, bilinmiyorsa mutlak banttan. Veri hiç yoksa
    /// nil — nötr rengi çağıran seçer (topbar `textSecondary`, satır `textMuted`).
    static func color(for window: UsageWindow, now: Date = Date()) -> Color? {
        if let pace = UsagePace(
            percentUsed: window.percentUsed,
            elapsedFraction: window.elapsedFraction(now: now)
        ) {
            return pace.color
        }
        return window.percentUsed.map { UsageLevel(percent: $0).color }
    }
}
