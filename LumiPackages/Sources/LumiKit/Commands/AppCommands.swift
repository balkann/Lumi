import Foundation

/// Uygulamanın komut tablosu — kısayolların TEK kaynağı (design/03 §2,
/// refactor 3.5). `MainMenuBuilder` menüyü, `MenuActionDispatcher` handler
/// kaydını, `ShortcutReference` Settings tablosunu BURADAN üretir.
///
/// Yeni komut eklemek = bu tabloya bir satır + dispatcher'da bir handler.
///
/// Tablo `IndexShortcutStyle` ile parametriktir (karar 58): indeksli iki ailenin
/// (repo tab'ı / terminal) ⌘ ve ⌃ değiştiricileri ayardan gelir. Ham tablo
/// private'tır — tüketiciler `all(_:)` / `commands(in:style:)` / `reference(_:)`
/// üzerinden okur, böylece hiçbir yol düzeni atlayamaz.
public enum AppCommands {
    /// Ham tablo: indeksli komutların değiştiricileri VARSAYILAN düzendedir.
    private static let table: [AppCommand] = [
        // MARK: App
        AppCommand(
            id: .openSettings, title: "Settings…", menu: .app, key: ",",
            referenceTitle: "Settings", referenceOrder: 15
        ),
        // Standart `NSApplication.terminate(_:)` selector'ına gider ama
        // kullanıcıya sunulan tabloda listelenir.
        AppCommand(
            id: .quit, title: "Quit Lumi", menu: .app, key: "q",
            separatorBefore: true, referenceTitle: "Quit", referenceOrder: 16
        ),

        // MARK: Shell
        AppCommand(
            id: .newTerminal, title: "New Terminal", menu: .shell, key: "t",
            referenceTitle: "New Terminal", referenceOrder: 1
        ),
        // ⌘W terminali kapatır, pencereyi DEĞİL (design/03 §2 — menü interception).
        AppCommand(
            id: .closeTerminal, title: "Close Terminal", menu: .shell, key: "w",
            referenceTitle: "Close Terminal", referenceOrder: 2
        ),
        AppCommand(
            id: .openRepoSelector, title: "Open Repo…", menu: .shell, key: "o",
            separatorBefore: true, referenceTitle: "Open Repository", referenceOrder: 3
        ),
        // ⌃1…⌃9 repo TAB'ını değiştirir (Electron paritesi). ⌘1…⌘9 ise aktif
        // repo içindeki terminali odaklar — ikisi ayrı eksendir (karar 55).
        // Değiştiriciler ayardan takas edilebilir (karar 58).
        AppCommand(
            id: .switchToTabAtIndex, title: "Repository", menu: .shell, key: nil,
            modifiers: IndexShortcutStyle.default.repoModifiers,
            separatorBefore: true, indexRange: 1...9,
            referenceTitle: "Switch to Tab N", referenceOrder: 4
        ),

        // MARK: Edit (terminal copy-paste için ZORUNLU, design/03 §2)
        AppCommand(id: .cut, title: "Cut", menu: .edit, key: "x", isSystemStandard: true),
        AppCommand(id: .copy, title: "Copy", menu: .edit, key: "c", isSystemStandard: true),
        AppCommand(id: .paste, title: "Paste", menu: .edit, key: "v", isSystemStandard: true),
        AppCommand(
            id: .selectAll, title: "Select All", menu: .edit, key: "a",
            isSystemStandard: true
        ),

        // MARK: Terminal
        AppCommand(
            id: .focusNextTerminal, title: "Next Terminal", menu: .terminal,
            key: CommandKey.rightArrow, modifiers: [.command, .shift],
            referenceTitle: "Next Terminal", referenceOrder: 7
        ),
        AppCommand(
            id: .focusPreviousTerminal, title: "Previous Terminal", menu: .terminal,
            key: CommandKey.leftArrow, modifiers: [.command, .shift],
            referenceTitle: "Previous Terminal", referenceOrder: 6
        ),
        AppCommand(
            id: .focusTerminalAtIndex, title: "Terminal", menu: .terminal, key: nil,
            modifiers: IndexShortcutStyle.default.terminalModifiers,
            separatorBefore: true, indexRange: 1...9,
            referenceTitle: "Focus Terminal N", referenceOrder: 5
        ),
        AppCommand(
            id: .toggleMaximizeTerminal, title: "Maximize Terminal", menu: .terminal,
            key: "m", modifiers: [.command, .control], separatorBefore: true,
            referenceTitle: "Maximize Terminal", referenceOrder: 8
        ),

        // MARK: View
        AppCommand(
            id: .toggleLeftSidebar, title: "Toggle Left Sidebar", menu: .view, key: "b",
            referenceTitle: "Toggle Left Sidebar", referenceOrder: 9
        ),
        AppCommand(
            id: .toggleRightSidebar, title: "Toggle Right Sidebar", menu: .view, key: "B",
            modifiers: [.command, .shift],
            referenceTitle: "Toggle Right Sidebar", referenceOrder: 10
        ),
        AppCommand(
            id: .toggleFocusMode, title: "Toggle Focus Mode", menu: .view, key: "F",
            modifiers: [.command, .shift], separatorBefore: true,
            referenceTitle: "Focus Mode", referenceOrder: 11
        ),
        // Karar 57: tüm arayüzü ölçekler (Electron `zoomIn`/`zoomOut`/
        // `resetZoom` paritesi) — yalnız terminal fontunu değil.
        AppCommand(
            id: .zoomIn, title: "Zoom In", menu: .view, key: "+",
            separatorBefore: true, referenceTitle: "Zoom In", referenceOrder: 12
        ),
        AppCommand(
            id: .zoomOut, title: "Zoom Out", menu: .view, key: "-",
            referenceTitle: "Zoom Out", referenceOrder: 13
        ),
        AppCommand(
            id: .resetZoom, title: "Actual Size", menu: .view, key: "0",
            referenceTitle: "Actual Size", referenceOrder: 14
        ),

        // MARK: Window
        AppCommand(
            id: .minimizeWindow, title: "Minimize", menu: .window, key: "m",
            isSystemStandard: true
        ),
    ]

    /// Komut tablosu, indeksli kısayol düzeni uygulanmış hâlde (karar 58).
    public static func all(_ style: IndexShortcutStyle = .default) -> [AppCommand] {
        table.map { command in
            switch command.id {
            case .switchToTabAtIndex: return command.withModifiers(style.repoModifiers)
            case .focusTerminalAtIndex: return command.withModifiers(style.terminalModifiers)
            default: return command
            }
        }
    }

    /// Menü bölümü sırasına göre gruplanmış komutlar (tablo sırası korunur).
    public static func commands(
        in section: MenuSection,
        style: IndexShortcutStyle = .default
    ) -> [AppCommand] {
        all(style).filter { $0.menu == section }
    }

    /// Settings ▸ Shortcuts tablosunun kaynağı: platform standardı olmayan,
    /// referans etiketi taşıyan komutlar, `referenceOrder` sırasında.
    public static func reference(_ style: IndexShortcutStyle = .default) -> [AppCommand] {
        all(style)
            .filter { !$0.isSystemStandard && $0.referenceTitle != nil }
            .sorted { ($0.referenceOrder ?? .max) < ($1.referenceOrder ?? .max) }
    }
}
