import Foundation

/// Terminal ekranından okunan interaktif seçim promptu (spec 4).
/// `kind` best-effort'tur; yalnız kart başlığını etkiler, davranışı değil.
public struct DetectedPrompt: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case permission   // izin/onay diyaloğu ("don't ask again" / proceed)
        case question     // AskUserQuestion menüsü (to select / to navigate)
        case generic
    }

    public let kind: Kind
    /// Seçeneklerin hemen üstündeki soru/başlık bloğu; yoksa nil.
    public let questionText: String?
    /// Ekranda göründüğü sırayla seçenek etiketleri.
    public let options: [String]

    public init(kind: Kind, questionText: String?, options: [String]) {
        self.kind = kind
        self.questionText = questionText
        self.options = options
    }
}
