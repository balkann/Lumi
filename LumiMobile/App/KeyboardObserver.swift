import SwiftUI
import UIKit

/// Publishes the keyboard's visible height (the overlap above the safe area).
///
/// Why manual (bug #1): in the terminal + bottom input bar layout, SwiftUI's automatic
/// `.safeAreaInset` keyboard avoidance was not moving the bar above the keyboard
/// (UIViewRepresentable-heavy hierarchy). This observer watches the keyboard frame
/// directly; the view disables automatic avoidance with `.ignoresSafeArea(.keyboard)`
/// and applies this height as bottom padding → the bar always stays above the keyboard.
@MainActor
final class KeyboardObserver: ObservableObject {
    /// The keyboard's visible height with the portion below the safe area subtracted.
    @Published var height: CGFloat = 0

    // Marked unsafe so deinit (nonisolated) can access it; only init (main) writes, dealloc reads.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // `note` is non-Sendable → extract the Sendable CGRect BEFORE hopping to main.
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
        // Subtract the safe area (home indicator) since it is already reserved by the layout;
        // otherwise ~34pt would be double-counted.
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
