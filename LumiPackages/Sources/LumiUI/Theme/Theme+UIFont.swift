import LumiKit
import SwiftUI

/// Arayüz yazı tipi (karar 63) — Electron sürümünün tipografi paritesi.
///
/// **Neden token kaynağında, çağrı yerinde DEĞİL:** LumiUI'da her metin
/// `Theme.Typography` fabrikalarından geçer (`DesignTokenLintTests` literal
/// puntoyu yasaklar), bu yüzden yüz seçimi tek noktadan tüm arayüze iner —
/// `Theme.uiScale` (karar 61) ile aynı desen.
///
/// `nonisolated(unsafe)`: yalnız `LayoutStore` köprüsünden (MainActor) yazılır,
/// okuyanlar view body'leridir (`uiScale` ile aynı gerekçe).
public extension Theme {
    nonisolated(unsafe) static var uiFontFamily: UIFontFamily = .system

    /// Ölçeklenmiş puntoyu yürürlükteki yüze bağlar.
    ///
    /// JetBrains Mono seçiliyken ağırlık, sentetik kalınlaştırmayla değil
    /// bundle'daki dört ayrı yüzle (400/500/600/700) karşılanır — Electron'un
    /// Google Fonts'tan çektiği ağırlık kümesiyle aynı. Yüzler kayıtlı değilse
    /// sistem monospace'ine düşülür: `Font.custom` kayıtsız bir adda sessizce
    /// ORANTILI sistem fontuna düşer ve monospace hizası çökerdi.
    static func monoFont(size: CGFloat, weight: Font.Weight) -> Font {
        guard uiFontFamily == .jetBrainsMono, LumiFonts.isBundledUIFontAvailable else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(LumiFonts.uiPostScriptName(for: weight), fixedSize: size)
    }
}
