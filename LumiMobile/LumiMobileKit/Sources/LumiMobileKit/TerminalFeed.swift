import Foundation

/// Abstract receiver that applies raw terminal chunks to a SwiftTerm view.
/// The adapter in the app target wraps the real `TerminalView`; tests use a fake.
/// `@MainActor`: SwiftTerm views can only be fed from the main actor.
@MainActor
public protocol TerminalFeeder: AnyObject {
    func resize(cols: Int, rows: Int)
    func reset()
    func feed(bytes: [UInt8])
}

/// Buffers incoming chunks until the view is ready; once attached, drains the
/// buffer IN ORDER and applies subsequent chunks immediately.
///
/// Root cause (bug #3 — "terminal always empty"): the old design saved the SwiftTerm
/// view reference via `@State`; that `@State` write performed inside a view-update
/// was dropped/deferred by SwiftUI, so the view reference was never populated and
/// all chunks stayed in a local buffer that only drained when the next chunk arrived
/// → terminal permanently empty. This class holds the view reference as a reference
/// type (outside the SwiftUI update cycle) and drains the buffer at attach time, so
/// scrollback (seq=0) is visible even in idle sessions that produce no further output.
@MainActor
public final class TerminalFeedBuffer {
    private var feeder: TerminalFeeder?
    private var pending: [TerminalChunk] = []

    public init() {}

    /// Called when the real view is ready; applies accumulated chunks in order.
    public func attach(_ feeder: TerminalFeeder) {
        self.feeder = feeder
        let buffered = pending
        pending.removeAll()
        for chunk in buffered { apply(chunk) }
    }

    /// Called when the view disappears (onDisappear); subsequent chunks are buffered again.
    public func detach() {
        feeder = nil
    }

    /// Applies a chunk; buffers it if no view is attached.
    public func feed(_ chunk: TerminalChunk) {
        guard feeder != nil else {
            pending.append(chunk)
            return
        }
        apply(chunk)
    }

    /// Test visibility: number of pending (not yet applied) chunks.
    public var pendingCount: Int { pending.count }

    private func apply(_ chunk: TerminalChunk) {
        guard let feeder else { return }
        if let cols = chunk.cols, let rows = chunk.rows {
            feeder.resize(cols: cols, rows: rows)
        }
        // seq==0: scrollback / reconnect one-shot → reset the emulator.
        if chunk.seq == 0 {
            feeder.reset()
        }
        feeder.feed(bytes: [UInt8](chunk.bytes))
    }
}
