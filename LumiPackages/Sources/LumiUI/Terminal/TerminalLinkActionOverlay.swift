import AppKit
import LumiKit
import LumiState
import SwiftUI

/// Popover'ın kabuk içindeki yerleşimi (karar 57) — saf hesap.
///
/// Varsayılan yer tık noktasının hemen ALTIDIR; aşağı sığmazsa üste taşınır,
/// sağa taşarsa sola çekilir. Sonuç her zaman kabın içinde kalır.
enum TerminalLinkPopoverPlacement {
    static let gap = Theme.Spacing.md

    static func origin(anchor: CGPoint, popoverSize: CGSize, container: CGSize) -> CGPoint {
        let maxX = max(gap, container.width - popoverSize.width - gap)
        let x = min(max(gap, anchor.x), maxX)
        let below = anchor.y + gap
        let fitsBelow = below + popoverSize.height + gap <= container.height
        let y = fitsBelow ? below : anchor.y - gap - popoverSize.height
        let maxY = max(gap, container.height - popoverSize.height - gap)
        return CGPoint(x: x, y: min(max(gap, y), maxY))
    }
}

/// Açık link eylemi popover'ını tık noktasında çizen overlay (karar 57).
/// Dışarı tıklama ve Esc kapatır; eylem seçilince kabuk niyeti yürütür.
public struct TerminalLinkActionOverlay: View {
    @Shell private var shell
    @State private var popoverSize: CGSize = .zero

    private struct SizeKey: PreferenceKey {
        static let defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
    }

    public init() {}

    public var body: some View {
        if let request = shell.terminalLinks.request {
            GeometryReader { geometry in
                let origin = TerminalLinkPopoverPlacement.origin(
                    anchor: request.anchor,
                    popoverSize: popoverSize,
                    container: geometry.size
                )
                ZStack(alignment: .topLeading) {
                    // Dışarı tıklama kapatır; terminale de gitmez.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { shell.terminalLinks.dismiss() }
                    TerminalLinkActionPopover(
                        request: request,
                        onRun: { shell.terminalLinks.perform($0) },
                        onCopy: { copy(request.destination) },
                        onOpenSettings: {
                            shell.terminalLinks.dismiss()
                            shell.dialogs.openSettings(tab: SettingsTab.terminal.rawValue)
                        }
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: SizeKey.self, value: proxy.size)
                        }
                    )
                    .offset(x: origin.x, y: origin.y)
                    // Ölçüm tamamlanana kadar (ilk frame) çizilmez: aksi hâlde
                    // popover bir kare yanlış yerde görünürdü.
                    .opacity(popoverSize == .zero ? 0 : 1)
                }
                .onPreferenceChange(SizeKey.self) { size in
                    Task { @MainActor in popoverSize = size }
                }
            }
            .onExitCommand { shell.terminalLinks.dismiss() }
            .id(request.id)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        shell.terminalLinks.dismiss()
        shell.toasts.show(.info, title: "Copied", message: value)
    }
}
