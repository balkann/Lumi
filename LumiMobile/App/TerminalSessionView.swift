import SwiftUI
import LumiMobileKit

/// Full-screen terminal view for a single Claude Code session.
/// Renders raw PTY bytes via SwiftTerm and forwards user input back to the Mac.
///
/// Accessory key bar (modifier keys, arrow cluster, etc.) is deferred to Task 10.
struct TerminalSessionView: View {
    let model: AppModel
    let sessionId: String

    /// View hazır olana dek chunk'ları tamponlayıp attach anında boşaltan referans-tip
    /// tampon (bug #3: eski `@State` view handshake'i chunk'ları hiç teslim etmiyordu).
    @State private var buffer = TerminalFeedBuffer()
    /// Klavye yüksekliğini izler; alt çubuğu manuel olarak klavyenin üstüne taşır (bug #1).
    @StateObject private var keyboard = KeyboardObserver()
    @State private var showChat = true

    var body: some View {
        Group {
            if showChat {
                MobileChatView(model: model, sessionId: sessionId)
            } else {
                terminalBody
            }
        }
        .onDisappear { model.unsubscribe(sessionId) }
        .navigationTitle(model.session(sessionId)?.repoName ?? "Oturum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showChat.toggle()
                } label: {
                    Image(systemName: showChat ? "terminal" : "bubble.left.and.bubble.right")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { toolbarItems }
        }
    }

    /// Mevcut terminal-mirror gövdesi (VStack + klavye padding + .task subscribe/feed).
    private var terminalBody: some View {
        VStack(spacing: 0) {
            TerminalHostView(onInput: { model.sendInput(sessionId, $0) }, buffer: buffer)
            AccessoryBar { model.sendInput(sessionId, $0) }
        }
        // Otomatik klavye kaçınmasını kapat; yüksekliği manuel uygula → çubuk daima
        // klavyenin üstünde, terminal onun üstünde kalır.
        .padding(.bottom, keyboard.height)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeOut(duration: 0.25), value: keyboard.height)
        .task(id: sessionId) {
            model.subscribe(sessionId)
            for await chunk in model.terminalStream(sessionId) {
                buffer.feed(chunk)
            }
        }
        .onDisappear {
            buffer.detach()
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
