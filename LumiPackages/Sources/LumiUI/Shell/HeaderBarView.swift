import LumiKit
import LumiState
import SwiftUI

/// Üst header çubuğu (ince yerleşim karar 30 — Orca paritesi). 36px,
/// traffic light'lar doğal macOS konumunda (karar 27/30: yükseklik ve leading
/// padding bu dosyanın DEĞİŞMEZLERİ — `TrafficLightLayout` aynı ölçüleri okur).
///
/// **Faz 6.4:** gövde artık elle dizilmiş bir HStack değil, üç bölgenin
/// (`leading` · `center` · `trailing`) `ToolbarRegistry`'den çözülüp
/// çizilmesidir. Header hiçbir özel kontrolün adını bilmez; hamburger, logo,
/// tab şeridi, grid ayarı, New <Provider>, usage göstergeleri, focus/git/
/// settings ikonlarının hepsi birer `ToolbarItemDescriptor`'dır ve kayıt yeri
/// composition root'tur. Yeni bir feature'ın bar'a öğe koyması = kendi
/// assembly'sinde tek `registries.toolbar.register(...)` satırı.
///
/// Focus mode'da header hiç çizilmez (`AppShellView`); bu view o kararı bilmez.
struct HeaderBarView: View {
    static let height: CGFloat = TopBarMetrics.height

    let registry: ToolbarRegistry

    @Shell private var shell

    var body: some View {
        // Karar 55: üç parça panellerle hizalıdır — sol parça sol panel, sağ
        // parça sağ panel genişliğinde; orta parça kalanı alır ve içeriği
        // (grid ayarı + New <Provider>) sağa yaslanır.
        HStack(spacing: 0) {
            region(.leading)
                .frame(width: leadingWidth, alignment: .leading)
            region(.center)
                .padding(.trailing, TopBarMetrics.regionGap)
                .frame(maxWidth: .infinity, alignment: .trailing)
            region(.trailing)
                .frame(width: trailingWidth, alignment: .trailing)
        }
        // Sol: traffic light alanı — içerik butonların sağından başlar
        .padding(.leading, TopBarMetrics.contentLeading)
        .padding(.trailing, TopBarMetrics.trailingPadding)
        .frame(height: Self.height)
        // Renk hit-test'i kapalı: boş alanlardaki tıklamalar arkadaki
        // WindowDragArea'ya geçsin (pencere sürükleme + çift-tık zoom).
        .background(Theme.bgSurface.allowsHitTesting(false))
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Theme.border.frame(height: 1)
        }
    }

    /// Yuva gizliyken `nil` (doğal genişlik) — hizalanacak panel yoktur.
    private var leadingWidth: CGFloat? {
        TopBarMetrics.leadingRegionWidth(leftPanelWidth: panelWidth(.left))
    }

    private var trailingWidth: CGFloat? {
        TopBarMetrics.trailingRegionWidth(rightPanelWidth: panelWidth(.right))
    }

    private func panelWidth(_ slot: PanelSlot) -> CGFloat? {
        guard shell.layout.isSlotVisible(slot) else { return nil }
        return CGFloat(shell.layout.width(for: slot))
    }

    private func region(_ region: ToolbarRegion) -> some View {
        HStack(spacing: region.spacing) {
            ForEach(registry.items(in: region, context: shell)) { item in
                item.makeView()
            }
        }
    }
}
