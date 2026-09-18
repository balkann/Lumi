import LumiKit
import LumiState
import SwiftUI

/// Topbar'da duran kompakt kullanım göstergesi (design/05, karar 32): sağlayıcı
/// marka ikonu + gösterge penceresinin yüzdesi (örn. "15%") — 5 saatlik oturum
/// varsa o, yoksa raporlanan ilk pencere. Tıklamada tüm limitleri
/// progress bar + reset süreleriyle gösteren popover açılır; popover'da manuel
/// refresh butonu vardır. Her açık sağlayıcı için bir örnek çizilir.
///
/// Gösterge gerçek bir `Button`'dır (Faz 7.6): `onTapGesture` klavye ve
/// VoiceOver için erişilemezdi.
public struct UsageIndicatorView: View {
    private let store: UsageStore
    /// Claude hesap değiştirici (karar 56). Yalnız Claude göstergesine
    /// verilir; nil ise popover eski hâliyle çizilir.
    private let accounts: ClaudeAccountStore?
    private let openAccountSettings: (() -> Void)?
    @State private var isPresented = false

    public init(
        store: UsageStore,
        accounts: ClaudeAccountStore? = nil,
        openAccountSettings: (() -> Void)? = nil
    ) {
        self.store = store
        self.accounts = accounts
        self.openAccountSettings = openAccountSettings
    }

    public var body: some View {
        Button { isPresented.toggle() } label: { compact }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .help(helpText)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                UsagePopover(
                    store: store,
                    accounts: accounts,
                    openAccountSettings: openAccountSettings.map { open in
                        { isPresented = false; open() }
                    }
                )
            }
    }

    private var compact: some View {
        // 5pt: ölçek dışı ara değer (v1 paritesi korunuyor).
        HStack(spacing: Theme.scaled(5)) {
            ProviderIcon(provider: store.provider, size: .body)
            Text(label)
                // 11.5pt → ölçekte `label` (11); yuvarlama asla büyütmez.
                .font(Theme.Typography.mono(.label, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: TopBarMetrics.controlHeight)
        .background(Theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.border, lineWidth: Theme.Stroke.hairline)
        )
        .contentShape(Rectangle())
    }

    private var label: String {
        if let percent = store.indicatorPercent { return "\(percent)%" }
        if store.isLoading { return "…" }
        return "—"
    }

    /// Hangi pencerenin gösterildiği tooltip'te söylenir: Codex'in yeni
    /// planlarında bu haftalık limittir, "%N" tek başına yanıltıcı olurdu.
    private var helpText: String {
        let base = "\(store.provider.displayName) usage"
        guard let title = store.indicatorLimit?.displayTitle else { return base }
        return "\(base) — \(title)"
    }

    private var accessibilityLabel: String {
        guard let percent = store.indicatorPercent else {
            return "\(store.provider.displayName) usage, unavailable"
        }
        let window = store.indicatorLimit?.displayTitle ?? "usage"
        return "\(store.provider.displayName) \(window), \(percent) percent"
    }

    private var tint: Color {
        guard let percent = store.indicatorPercent else { return Theme.textSecondary }
        return UsageLevel(percent: percent).color
    }
}

/// Tüm kullanım pencerelerini + refresh'i gösteren popover içeriği.
private struct UsagePopover: View {
    let store: UsageStore
    var accounts: ClaudeAccountStore?
    var openAccountSettings: (() -> Void)?

    /// Popover'ın sabit genişliği ve iç kenar payı; ikisi de ölçek dışı ara
    /// değerler (v1 paritesi).
    private enum Metrics {
        static var width: CGFloat { Theme.scaled(320) }
        static var inset: CGFloat { Theme.scaled(14) }
        static var rowInset: CGFloat { Theme.scaled(10) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: Theme.Stroke.hairline)
            content
                .padding(Metrics.inset)
            accountSection
            footer
        }
        .frame(width: Metrics.width)
        .background(Theme.bgElevated)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProviderIcon(provider: store.provider, size: .base)
            Text("\(store.provider.displayName) Usage")
                .font(Theme.Typography.mono(.base, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            refreshButton
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.rowInset)
    }

    /// `IconButton` değil: yükleme sırasında ikonun yerini bir `ProgressView`
    /// alır, yani "ikonu-tek buton" sözleşmesine girmez.
    private var refreshButton: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Group {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Typography.ui(.body, weight: .semibold))
                }
            }
            .frame(width: TopBarMetrics.controlHeight, height: TopBarMetrics.controlHeight)
            .foregroundStyle(store.canRefresh ? Theme.accentPrimary : Theme.textMuted)
            .background(Theme.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.canRefresh)
        .accessibilityLabel("Refresh \(store.provider.displayName) usage")
        .help(store.canRefresh ? "Refresh" : "Too frequent — wait a bit")
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: Metrics.inset) {
                // Limit sayısı CLI'a göre değişir (model satırları eklenip
                // kaldırılabilir) → listeyi olduğu gibi gez.
                ForEach(snapshot.limits) { limit in
                    UsageWindowRow(title: limit.displayTitle, window: limit.window)
                }
                if snapshot.limits.isEmpty {
                    Text("No limit reported.")
                        .font(Theme.Typography.bodyMono)
                        .foregroundStyle(Theme.textSecondary)
                }
                if snapshot.mode == .apiKey {
                    Text("API key mode — no subscription limit.")
                        .font(Theme.Typography.labelMono)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        } else if store.isLoading {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(Theme.Typography.bodyMono)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            Text(store.errorMessage ?? "No usage data.")
                .font(Theme.Typography.bodyMono)
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hesap değiştirici (karar 56) — yalnız hesap store'u verilmiş
    /// göstergede (Claude) çizilir.
    @ViewBuilder
    private var accountSection: some View {
        if let accounts {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Rectangle().fill(Theme.border).frame(height: Theme.Stroke.hairline)
                ClaudeAccountSwitcher(store: accounts, openSettings: openAccountSettings)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.bottom, Metrics.rowInset)
            }
        }
    }

    /// Alt bilgi Settings'teki satırla AYNI bileşendir (refactor 7.9);
    /// `.idle` durumunda hiç çizilmez.
    @ViewBuilder
    private var footer: some View {
        if store.statusKind != .idle {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Rectangle().fill(Theme.border).frame(height: Theme.Stroke.hairline)
                UsageStatusRow(kind: store.statusKind)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.bottom, Metrics.rowInset)
            }
        }
    }
}

/// Tek pencere satırı: başlık + yüzde + progress bar + reset zamanı.
/// (internal — `fillFraction` ve `paceFraction` clamp'i birim testten
/// görünür olsun diye.)
struct UsageWindowRow: View {
    let title: String
    let window: UsageWindow
    /// Yalnız test için enjekte edilir; pencerenin ne kadarının geçtiğini
    /// hesaplarken kullanılır (karar 74).
    var now: Date = Date()

    /// Progress bar yüksekliği; yarıçap `Radius.sm` (4) yüksekliğin yarısına
    /// (3) kırpılır, yani v1'deki 3pt köşeyle birebir aynı çizilir.
    private static var barHeight: CGFloat { Theme.scaled(6) }
    /// Tempo çizgisinin kalınlığı — hairline (1) barın üstünde kayboluyordu.
    private static var paceMarkerWidth: CGFloat { Theme.scaled(2) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(title)
                    .font(Theme.Typography.bodyMono)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(percentText)
                    .font(Theme.Typography.mono(.body, weight: .semibold))
                    .foregroundStyle(percentColor)
            }
            progressBar
            if !resetText.isEmpty {
                Text(resetText)
                    .font(Theme.Typography.captionMono)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.bgDeep)
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(percentColor)
                    .frame(width: geo.size.width * fillFraction)
                if let pace = paceFraction {
                    // Dolgunun ÜSTÜNDE durur: çizginin solunda kalan dolgu
                    // "planın önündeyiz", sağına taşan dolgu "limiti saatten
                    // hızlı tüketiyoruz" demektir (karar 74).
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.textPrimary)
                        .frame(width: Self.paceMarkerWidth)
                        .offset(x: Self.markerOffset(for: pace, width: geo.size.width))
                }
            }
        }
        .frame(height: Self.barHeight)
        .help(paceHelp ?? "")
        .accessibilityHidden(true)
    }

    var fillFraction: CGFloat {
        guard let percent = window.percentUsed else { return 0 }
        return CGFloat(min(100, max(0, percent))) / 100
    }

    /// Pencerenin geçen kısmı (0–1) — süresi bildirilmeyen sağlayıcıda (Claude
    /// OAuth yanıtı) nil, yani çizgi hiç çizilmez.
    var paceFraction: CGFloat? {
        window.elapsedFraction(now: now).map { CGFloat($0) }
    }

    /// Çizgi barın içinde kalır: uçlarda yarısı dışarı taşarsa kullanıcı
    /// "%0" ile "%2"yi ayırt edemez.
    static func markerOffset(for fraction: CGFloat, width: CGFloat) -> CGFloat {
        let centred = width * fraction - paceMarkerWidth / 2
        return min(max(0, centred), max(0, width - paceMarkerWidth))
    }

    /// Çizginin ne anlama geldiğini söyleyen tooltip; yüzde ile tempo farkı
    /// puan cinsindendir (ikisi de 0–100 ölçeğinde).
    var paceHelp: String? {
        guard let pace = paceFraction else { return nil }
        let elapsed = Int((pace * 100).rounded())
        guard let percent = window.percentUsed else { return "Window \(elapsed)% elapsed" }
        let delta = percent - elapsed
        let verdict: String
        switch delta {
        case 0: verdict = "on pace"
        case ..<0: verdict = "\(-delta) pt under pace"
        default: verdict = "\(delta) pt over pace"
        }
        return "Window \(elapsed)% elapsed · \(verdict)"
    }

    private var percentText: String {
        window.percentUsed.map { "\($0)%" } ?? "—"
    }

    private var percentColor: Color {
        window.percentUsed.map { UsageLevel(percent: $0).color } ?? Theme.textMuted
    }

    private var resetText: String {
        UsageStatusFormatter.resetText(for: window)
    }
}

#if DEBUG
#Preview("UsageIndicatorView") {
    HStack(spacing: Theme.Spacing.lg) {
        ForEach(AgentProvider.allCases, id: \.self) { provider in
            UsageIndicatorView(store: .preview(provider: provider))
        }
    }
    .padding(Theme.Spacing.xxl)
    .background(Theme.bgDeep)
}

#Preview("UsagePopover") {
    UsagePopover(store: .preview(provider: .claude), accounts: .preview)
        .background(Theme.bgDeep)
}
#endif
