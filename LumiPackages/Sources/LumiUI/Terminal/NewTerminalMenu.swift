import LumiKit
import SwiftUI

/// Split-button dropdown'unun İÇERİĞİ (karar 54).
///
/// İki çağıran vardır — topbar öğesi ve "bu repoda terminal yok" placeholder'ı;
/// liste burada TEK yerde kurulur. Ana buton aktif sağlayıcıyı açtığı için o
/// sağlayıcı listeye girmez.
@MainActor
enum NewTerminalMenu {
    static func items(shell: ShellContext, repoPath: String) -> [NewTerminalMenuItem] {
        let active = shell.settings.current.aiProvider
        var items = AgentProvider.allCases
            .filter { $0 != active }
            .map { provider in
                NewTerminalMenuItem(label: "New \(provider.displayName)", glyph: .provider(provider)) {
                    shell.terminals.spawn(in: repoPath, command: provider.launchCommand)
                }
            }
        items.append(NewTerminalMenuItem(label: "New DeepSeek", glyph: .symbol("sparkles")) {
            // Kurulu değilse store toast atar ve terminal açılmaz.
            guard let command = shell.deepSeek.launchCommandOrWarn() else { return }
            shell.terminals.spawn(in: repoPath, command: command, task: "DeepSeek")
        })
        items.append(NewTerminalMenuItem(label: "New Bash", glyph: .symbol("terminal")) {
            shell.terminals.spawn(in: repoPath, task: "Bash")
        })
        return items
    }
}
