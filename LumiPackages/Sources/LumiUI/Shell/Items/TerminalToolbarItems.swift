import LumiKit
import SwiftUI

/// Üretim bölgesi öğeleri (terminal feature'ının katkısı, Faz 6.4).
///
/// İkisi de yalnız **aktif repo route'unda** görünür — descriptor'ların
/// `isVisible` kapısı `TerminalFeatureAssembly`'de yazılıdır; repo-dışı bir
/// route (`.content`) veya hiç tab yokken (`.none`) `activeRepoPath` nil olduğu
/// için bar'dan düşerler (eski `if let active = shell.activeRepoPath` bloğunun
/// yapısal karşılığı).
public struct GridSettingsToolbarItem: View {
    @Shell private var shell

    public init() {}

    public var body: some View {
        if let repoPath = shell.activeRepoPath {
            GridSettingsControl(
                layout: shell.layout.gridLayout(for: repoPath),
                onChange: { shell.layout.setGridLayout($0, for: repoPath) }
            )
        }
    }
}

/// Birincil CTA (New <Provider>).
///
/// Karar 55: üretim ↔ durum ayracı (dikey çizgi + payı) kaldırıldı — bar üç
/// parçaya bölündüğünden grubun sonunu artık bölge sınırı işaret ediyor,
/// butonun sağındaki çizgi ve boşluk gereksizdi.
public struct NewTerminalToolbarItem: View {
    @Shell private var shell

    public init() {}

    public var body: some View {
        if let repoPath = shell.activeRepoPath {
            NewTerminalButton(
                provider: shell.settings.current.aiProvider,
                onNewProvider: {
                    shell.terminals.spawn(
                        in: repoPath,
                        command: shell.settings.current.aiProvider.launchCommand
                    )
                },
                items: NewTerminalMenu.items(shell: shell, repoPath: repoPath)
            )
        }
    }
}
