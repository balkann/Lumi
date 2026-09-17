import Foundation

/// İndeksli (1…9) kısayolların hangi eksene bağlandığı (karar 62).
///
/// İki indeksli kısayol ailesi vardır (karar 59): repo TAB geçişi ve aktif repo
/// içindeki terminal odağı. Hangisinin ⌘ hangisinin ⌃ olacağı kullanıcı
/// ayarıdır; varsayılan karar 59'teki Electron paritesidir.
public enum IndexShortcutStyle: String, Sendable, Equatable, CaseIterable {
    /// Varsayılan: ⌃1…⌃9 repo tab'ı, ⌘1…⌘9 terminal.
    case repoOnControl
    /// Takas: ⌘1…⌘9 repo tab'ı, ⌃1…⌃9 terminal.
    case repoOnCommand

    public static let `default` = IndexShortcutStyle.repoOnControl

    /// Bilinmeyen/eksik raw değer varsayılana düşer (karar 9 additive okuma).
    public static func normalized(_ raw: String?) -> IndexShortcutStyle {
        raw.flatMap(IndexShortcutStyle.init(rawValue:)) ?? .default
    }

    /// `switchToTabAtIndex` (repo tab geçişi) değiştiricisi.
    public var repoModifiers: CommandModifiers {
        self == .repoOnControl ? [.control] : [.command]
    }

    /// `focusTerminalAtIndex` (terminal odağı) değiştiricisi.
    public var terminalModifiers: CommandModifiers {
        self == .repoOnControl ? [.command] : [.control]
    }

    /// Settings ▸ Shortcuts segment etiketi.
    public var label: String {
        switch self {
        case .repoOnControl: return "⌃ Repo · ⌘ Terminal"
        case .repoOnCommand: return "⌘ Repo · ⌃ Terminal"
        }
    }
}
