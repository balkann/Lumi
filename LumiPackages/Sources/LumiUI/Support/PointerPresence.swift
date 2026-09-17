import AppKit
import SwiftUI

/// Fare varlığını **geometriden** doğrulayan hover sensörü (karar 59).
///
/// Kenar hover'ı (karar 44) SwiftUI `.onHover` ile kuruluydu ve üç yerde
/// yanlış cevap veriyordu:
///
/// 1. **Hiç açılmama:** şerit bir terminalin üstündeyken `TerminalEventMonitor`
///    `.mouseMoved`'ı yutuyor (`shouldConsumeHover`), SwiftUI hover'ı hiç
///    görmüyordu. Tracking area'lar `mouseEntered/Exited`'ı ayrı üretir; event
///    monitöründen bağımsızdır.
/// 2. **Popover açılınca kapanma:** `NSPopover` / `DropdownPanel` ayrı bir
///    pencere açar, SwiftUI "fare çıktı" der. Sensör, ana pencereye BAĞLI
///    (child) pencerelerin içini de "içeride" sayar.
/// 3. **Fare çıktığı hâlde kapanmama:** kaçan `mouseExited` (pencere
///    değişimi, hızlı çıkış, view yeniden kurulumu) tek başına bırakılmaz;
///    içerideyken düşük frekanslı bir doğrulama tik'i fiziksel imleç konumunu
///    okur ve gerçekten dışarıdaysa kapatır.
///
/// Sensör tıklama yutmaz: `hitTest` daima `nil` döner — altındaki terminal ya
/// da içerik davranışı değişmez.
struct PointerPresence: NSViewRepresentable {
    /// Varlık değişiminde çağrılır (yalnız değişimde, her tik'te değil).
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PointerPresenceView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PointerPresenceView)?.onChange = onChange
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? PointerPresenceView)?.tearDown()
    }
}

/// Sensörün **saf** kararı (test edilebilir): imleç bölgenin içinde mi?
///
/// Uygulama arka plandayken hover yoktur; bölgenin dışı, yalnız imleç ana
/// pencereye bağlı bir yardımcı pencerenin (popover, açılır liste) üstündeyse
/// içeride sayılır.
enum PointerPresenceRule {
    static func isInside(
        pointer: CGPoint,
        region: CGRect?,
        isAppActive: Bool,
        isPointerInAttachedWindow: Bool
    ) -> Bool {
        guard isAppActive, let region else { return false }
        return region.contains(pointer) || isPointerInAttachedWindow
    }
}

/// Tracking area + doğrulama tik'i taşıyan sensör view'ı.
private final class PointerPresenceView: NSView {
    var onChange: ((Bool) -> Void)?

    /// Kaçan `mouseExited`'a karşı doğrulama aralığı. Yalnız fare İÇERİDEYKEN
    /// döner; boşta hiçbir timer çalışmaz.
    private static let verifyInterval: TimeInterval = 0.1

    private var isInside = false
    private var verifyTimer: Timer?

    /// Sensör tamamen şeffaftır: tıklama ve sürükleme altındaki view'a gider.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        // Yeniden yerleşimde (şerit ↔ panel genişliği) varlık yeniden ölçülür.
        if isInside { evaluate() }
    }

    override func mouseEntered(with event: NSEvent) { evaluate() }

    override func mouseExited(with event: NSEvent) { evaluate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tearDown()
        } else {
            evaluate()
        }
    }

    func tearDown() {
        stopVerifying()
        if isInside {
            isInside = false
            onChange?(false)
        }
    }

    private func evaluate() {
        let inside = PointerPresenceRule.isInside(
            pointer: NSEvent.mouseLocation,
            region: screenRegion,
            isAppActive: NSApp.isActive,
            isPointerInAttachedWindow: isPointerInAttachedWindow
        )
        guard inside != isInside else { return }
        isInside = inside
        if inside { startVerifying() } else { stopVerifying() }
        onChange?(inside)
    }

    private func startVerifying() {
        guard verifyTimer == nil else { return }
        let timer = Timer(timeInterval: Self.verifyInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        // `.common`: kaydırma/sürükleme sırasında da dönmeli.
        RunLoop.main.add(timer, forMode: .common)
        verifyTimer = timer
    }

    private func stopVerifying() {
        verifyTimer?.invalidate()
        verifyTimer = nil
    }

    /// Bölgenin ekran koordinatındaki dikdörtgeni; pencere yoksa `nil`.
    private var screenRegion: CGRect? {
        guard let window, window.isVisible, !bounds.isEmpty else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    /// İmlecin altındaki pencere, ana pencereye bağlı bir yardımcı pencere mi
    /// (popover, açılır liste)? Bağlıysa panel açık kalmalıdır.
    private var isPointerInAttachedWindow: Bool {
        guard let window else { return false }
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard let hovered = NSApp.window(withWindowNumber: number), hovered !== window else { return false }
        var parent = hovered.parent
        while let candidate = parent {
            if candidate === window { return true }
            parent = candidate.parent
        }
        return false
    }
}
