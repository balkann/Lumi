import Foundation

/// Arayüz yazı tipi (karar 63) — Electron sürümüyle tipografi paritesi.
///
/// Karar 13 "JetBrains Mono tipografi native'de yeniden üretilir" diyordu ama
/// `Theme.Typography.mono` `.system(design: .monospaced)` (SF Mono) döndürüyordu;
/// JetBrains Mono yalnız terminal yüzeyinde kullanılıyordu. Tercih ayara
/// çıkarıldı: eski davranış default olarak KALIR, Electron paritesi seçenektir.
///
/// **Persistence yalnız `ConfigCodec` üzerinden — karar 9.**
public enum UIFontFamily: String, Sendable, CaseIterable {
    /// macOS sistem monospace yüzü (SF Mono) — mevcut/varsayılan davranış.
    case system
    /// Bundle'daki JetBrains Mono — `ai-orchestrator` (Electron) paritesi.
    case jetBrainsMono = "jetbrainsMono"

    /// Ayar ekranındaki etiket.
    public var displayName: String {
        switch self {
        case .system: return "System Mono"
        case .jetBrainsMono: return "JetBrains Mono"
        }
    }

    /// Bilinmeyen/bozuk değer varsayılana düşer — arayüz okunamaz bir yüzle açılmaz.
    public static func parse(_ raw: String?) -> UIFontFamily {
        raw.flatMap(UIFontFamily.init(rawValue:)) ?? .system
    }
}
