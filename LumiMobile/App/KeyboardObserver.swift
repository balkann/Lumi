import SwiftUI
import UIKit

/// Klavyenin görünür yüksekliğini (güvenli-alan üstünde kalan örtüşme) yayınlar.
///
/// Neden manuel (bug #1): terminal + alt giriş çubuğu düzeninde SwiftUI'nin
/// otomatik `.safeAreaInset` klavye kaçınması çubuğu klavyenin üstüne taşımıyordu
/// (UIViewRepresentable ağırlıklı hiyerarşi). Bu gözlemci klavye çerçevesini
/// doğrudan izler; view `.ignoresSafeArea(.keyboard)` ile otomatik kaçınmayı
/// kapatıp bu yüksekliği alt boşluk olarak uygular → çubuk daima klavyenin üstünde.
@MainActor
final class KeyboardObserver: ObservableObject {
    /// Klavyenin güvenli-alan altındaki kısmı çıkarılmış görünür yüksekliği.
    @Published var height: CGFloat = 0

    // deinit (nonisolated) erişebilsin diye unsafe; yalnız init (main) yazar, dealloc okur.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // `note` non-Sendable → main'e hop'lamadan ÖNCE Sendable CGRect'i çıkar.
            let frameEnd = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated { self?.update(frameEnd: frameEnd) }
        })
        tokens.append(nc.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.height = 0 }
        })
    }

    deinit {
        let nc = NotificationCenter.default
        for token in tokens { nc.removeObserver(token) }
    }

    private func update(frameEnd: CGRect?) {
        guard let frameEnd else { return }
        let screenHeight = UIScreen.main.bounds.height
        let overlap = max(0, screenHeight - frameEnd.origin.y)
        // Güvenli-alan (home indicator) zaten layout tarafından ayrıldığı için çıkar;
        // aksi halde ~34pt çift sayılır.
        let safeBottom = Self.safeAreaBottom()
        height = overlap <= 0 ? 0 : max(0, overlap - safeBottom)
    }

    private static func safeAreaBottom() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }
}
