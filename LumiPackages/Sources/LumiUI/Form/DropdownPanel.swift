import AppKit
import SwiftUI

/// Tetikleyicinin altına açılan kenarlıksız liste penceresi (karar 58).
///
/// SwiftUI `.popover` (yani `NSPopover`) burada iki sorun çıkarıyordu:
/// tema dışı duran ok ucu ve boyutun İLK yerleşimde sabitlenmesi — tembel
/// gelen dal listesi popover'ı büyütmüyor, kullanıcı kapatıp yeniden açmak
/// zorunda kalıyordu. Ayrıca liste, modalın `ScrollView`'ı içinde satır içi
/// çizilemez (kırpılır), o yüzden ayrı bir pencere gerekiyor.
///
/// Panel her güncellemede `fittingSize`'a göre yeniden boyutlanır, ana
/// pencerenin çocuğu olarak onunla birlikte hareket eder ve dışarıya
/// tıklama / Esc / kaydırma ile kapanır.
struct DropdownPanel<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    /// Alan ile liste arasındaki boşluk.
    private static var gap: CGFloat { Theme.Spacing.xxs }

    func makeNSView(context: Context) -> NSView { AnchorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDismiss = { isPresented = false }
        if isPresented {
            context.coordinator.present(content: content(), anchor: nsView, gap: Self.gap)
        } else {
            context.coordinator.close()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tıklamaları yutmasın: alan `.background` olarak tetikleyicinin altında
    /// duruyor, hit-test'ten tamamen çekilir.
    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        var onDismiss: () -> Void = {}
        private var panel: NSPanel?
        private weak var anchor: NSView?
        private var hosting: NSHostingView<AnyView>?
        private var monitor: Any?

        func present(content: Content, anchor: NSView, gap: CGFloat) {
            guard let window = anchor.window else { return }
            self.anchor = anchor
            let host: NSHostingView<AnyView>
            if let hosting {
                host = hosting
                host.rootView = AnyView(content)
            } else {
                host = NSHostingView(rootView: AnyView(content))
                hosting = host
            }
            let panel = self.panel ?? makePanel(hosting: host, parent: window)
            let size = host.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            panel.setFrame(NSRect(origin: origin(for: size, anchor: anchor, window: window, gap: gap), size: size), display: true)
        }

        func close() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            panel = nil
            hosting = nil
            anchor = nil
        }

        private func origin(for size: CGSize, anchor: NSView, window: NSWindow, gap: CGFloat) -> CGPoint {
            let field = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            var origin = CGPoint(x: field.minX, y: field.minY - size.height - gap)
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return origin }
            // Aşağıda yer yoksa alanın üstünde aç.
            if origin.y < visible.minY { origin.y = field.maxY + gap }
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            return origin
        }

        private func makePanel(hosting: NSHostingView<AnyView>, parent: NSWindow) -> NSPanel {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isFloatingPanel = true
            panel.level = .popUpMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovable = false
            panel.animationBehavior = .none
            panel.contentView = hosting
            parent.addChildWindow(panel, ordered: .above)
            self.panel = panel
            installMonitor()
            return panel
        }

        /// Dışarıya tıklama, kaydırma ve Esc listeyi kapatır. Esc yutulur,
        /// yoksa modalın kendisi de kapanırdı.
        private func installMonitor() {
            // `NSEvent` Sendable değil, o yüzden `assumeIsolated` yalnız yan
            // etki için koşar; olayın yutulup yutulmayacağı dışarıda taşınır.
            let handler: (NSEvent) -> NSEvent? = { [weak self] event in
                var swallow = false
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel else { return }
                    if event.type == .keyDown {
                        guard event.keyCode == dropdownEscapeKeyCode else { return }
                        self.onDismiss()
                        swallow = true
                        return
                    }
                    // Alanın kendisine tıklamak listeyi kapatmaz: arama
                    // alanına imleç koymak da bir "dışarı tıklama" sayılırdı.
                    if event.window !== panel, !self.isInsideAnchor(event) { self.onDismiss() }
                }
                return swallow ? nil : event
            }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown],
                handler: handler
            )
        }

        private func isInsideAnchor(_ event: NSEvent) -> Bool {
            guard let anchor, let window = anchor.window, event.window === window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
    }
}

/// Esc: listeyi kapatır (generic tipin içinde static depolanamıyor).
private let dropdownEscapeKeyCode: UInt16 = 53
