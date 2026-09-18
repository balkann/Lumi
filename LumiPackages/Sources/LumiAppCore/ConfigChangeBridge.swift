import Foundation
import LumiKit

/// Assembly olmayan gözlemcilerin (AppKit kabuğu) config yan etkisine
/// bağlanma yolu.
///
/// `ConfigSideEffectCoordinator` gözlemcilerini GÜÇLÜ tutar; AppDelegate'i
/// doğrudan kaydetmek kabuk ↔ container arasında bir döngü kurardı. Köprü
/// kapanışı `[weak self]` ile taşır: sahibi gidince yan etki sessizce durur.
@MainActor
final class ConfigChangeBridge: ConfigChangeObserving {
    private let handler: (AppConfig, AppConfig) -> Void

    init(_ handler: @escaping (AppConfig, AppConfig) -> Void) {
        self.handler = handler
    }

    func configDidChange(old: AppConfig, new: AppConfig) {
        handler(old, new)
    }
}
