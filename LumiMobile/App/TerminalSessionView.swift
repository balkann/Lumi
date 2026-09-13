import SwiftUI
import SwiftTerm
import LumiMobileKit

/// Full-screen terminal view for a single Claude Code session.
/// Renders raw PTY bytes via SwiftTerm and forwards user input back to the Mac.
///
/// Accessory key bar (modifier keys, arrow cluster, etc.) is deferred to Task 10.
struct TerminalSessionView: View {
    let model: AppModel
    let sessionId: String

    /// Strong reference to the live SwiftTerm view so we can feed bytes into it.
    @State private var terminalView: TerminalView?

    var body: some View {
        VStack(spacing: 0) {
            TerminalHostView(
                onInput: { data in
                    model.sendInput(sessionId, data)
                },
                register: { view in
                    terminalView = view
                }
            )
            .ignoresSafeArea(edges: .bottom)

            AccessoryBar { data in
                model.sendInput(sessionId, data)
            }
        }
        .task(id: sessionId) {
            model.subscribe(sessionId)
            for await chunk in model.terminalStream(sessionId) {
                guard let tv = terminalView else { continue }
                // Resize first when cols/rows are present (e.g. scrollback chunk header).
                if let cols = chunk.cols, let rows = chunk.rows {
                    await MainActor.run {
                        tv.resize(cols: cols, rows: rows)
                    }
                }
                // seq==0 → scrollback dump (initial subscribe or reconnect).
                // Reset the emulator before feeding so reconnect doesn't append a
                // duplicate scrollback on top of whatever was already rendered.
                if chunk.seq == 0 {
                    await MainActor.run {
                        tv.getTerminal().resetToInitialState()
                    }
                }
                // Feed raw bytes into the emulator.
                let bytes = [UInt8](chunk.bytes)
                await MainActor.run {
                    tv.feed(byteArray: bytes[...])
                }
            }
        }
        .onDisappear {
            model.unsubscribe(sessionId)
        }
        .navigationTitle(model.session(sessionId)?.repoName ?? "Oturum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarItems
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbarItems: some View {
        HStack(spacing: 12) {
            // Status badge
            if let meta = model.session(sessionId) {
                StatusBadge(badge: meta.badge)
            }

            // Model picker menu
            if let meta = model.session(sessionId) {
                modelMenu(for: meta)
            }
        }
    }

    @ViewBuilder
    private func modelMenu(for meta: SessionMeta) -> some View {
        let currentModel = model.currentModel(for: sessionId)
        let label = currentModel.map { model.modelLabel($0) } ?? "Model"
        Menu {
            Button("Haiku") {
                Task { await model.setModel(sessionId: sessionId, model: "claude-haiku-4-5") }
            }
            Button("Sonnet") {
                Task { await model.setModel(sessionId: sessionId, model: "claude-sonnet-4-5") }
            }
            Button("Opus") {
                Task { await model.setModel(sessionId: sessionId, model: "claude-opus-4-5") }
            }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
    }
}
