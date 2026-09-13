import SwiftUI
import SwiftTerm

/// UIViewRepresentable wrapping SwiftTerm's TerminalView for iOS.
/// - `onInput`: called when the user types in the terminal (sends bytes to Mac PTY).
/// - `register`: called once with the created TerminalView so the SwiftUI parent
///   can hold a reference and feed bytes into it later.
struct TerminalHostView: UIViewRepresentable {
    // Both closures are @Sendable + @MainActor-bound because TerminalView is a UIView
    // (main-actor only). `onInput` is @Sendable for Swift 6 strict concurrency.
    let onInput: @MainActor (Data) -> Void
    let register: @MainActor (TerminalView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput)
    }

    @MainActor
    func makeUIView(context: Context) -> TerminalView {
        let v = TerminalView(frame: .zero)
        v.terminalDelegate = context.coordinator
        register(v)
        return v
    }

    @MainActor
    func updateUIView(_ uiView: TerminalView, context: Context) {}

    // MARK: - Coordinator

    // Isolated conformance: SwiftTerm's TerminalView is a UIView and only ever
    // invokes its delegate on the main thread, so the delegate conformance is
    // safely main-actor-isolated (Swift 6 strict concurrency).
    @MainActor
    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        let onInput: (Data) -> Void

        init(onInput: @escaping (Data) -> Void) {
            self.onInput = onInput
        }

        // MARK: Required delegate methods (no default implementations on iOS)

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Terminal resize initiated by client side; no action needed from host.
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Could propagate to navigation title; handled in TerminalSessionView instead.
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // No-op: directory tracking not used in this context.
        }

        func scrolled(source: TerminalView, position: Double) {
            // No-op: scrollbar UI not implemented in this version.
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            // No-op: change notifications not used.
        }

        // Note: bell, iTermContent, clipboardCopy, clipboardRead have default
        // implementations provided by SwiftTerm's extension TerminalViewDelegate.
    }
}
