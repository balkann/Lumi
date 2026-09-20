import SwiftUI
import SwiftTerm
import LumiMobileKit

/// Mirror terminal view: displays the Mac's PTY bytes; input comes only from AccessoryBar.
/// The terminal must NOT open its OWN keyboard — otherwise touching the terminal makes
/// SwiftTerm become the first responder, opening its own keyboard and competing with the
/// AccessoryBar TextField (bug #1: "can't type after scrolling up", bar stuck under keyboard).
final class MirrorTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
    override var canBecomeFocused: Bool { false }
}

/// Wraps a real `TerminalView` as a `TerminalFeeder` (LumiMobileKit boundary).
@MainActor
final class TerminalViewFeeder: TerminalFeeder {
    private let view: TerminalView
    init(_ view: TerminalView) { self.view = view }
    func resize(cols: Int, rows: Int) { view.resize(cols: cols, rows: rows) }
    func reset() { view.getTerminal().resetToInitialState() }
    func feed(bytes: [UInt8]) { view.feed(byteArray: bytes[...]) }
}

/// UIViewRepresentable wrapping SwiftTerm's TerminalView for iOS.
/// - `onInput`: called when the user types in the terminal (sends bytes to Mac PTY).
/// - `buffer`: `attach`ed once the view is ready; a reference-type buffer is used
///   instead of a SwiftUI `@State` handshake (see `TerminalFeedBuffer` — bug #3).
struct TerminalHostView: UIViewRepresentable {
    let onInput: @MainActor (Data) -> Void
    let buffer: TerminalFeedBuffer

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput)
    }

    @MainActor
    func makeUIView(context: Context) -> TerminalView {
        let v = MirrorTerminalView(frame: .zero)
        v.terminalDelegate = context.coordinator
        // View ready: attach the buffer → accumulated scrollback/data is applied immediately.
        buffer.attach(TerminalViewFeeder(v))
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
