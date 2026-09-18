// LumiMobile/App/MobileChatView.swift
import SwiftUI
import LumiMobileKit
import Foundation

/// Native chat görünümü: transcript'ten türeyen mesajları satır-saran balonlar
/// olarak gösterir (yatay scroll yok). Composer serbest metin gönderir.
struct MobileChatView: View {
    let model: AppModel
    let sessionId: String

    @StateObject private var keyboard = KeyboardObserver()
    @State private var draft = ""

    private var turns: [FoldedTurn] { foldChatMessages(model.chatMessages(sessionId)) }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if turns.isEmpty {
                                Text("Sohbet yükleniyor…")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }
                            ForEach(turns) { turn in
                                MobileChatMessageView(turn: turn).id(turn.id)
                            }
                            // Canlı streaming prose: turn bitmeden transcript'e düşmemiş
                            // assistant metni balonsuz olarak mesaj listesinin sonunda gösterilir.
                            if let streaming = model.chatStreamingText(sessionId) {
                                Text(streaming)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: turns.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                let pending = model.prompts[sessionId]?.last(where: { $0.state == .pending })
                if let status = model.turnStatus[sessionId], status.working {
                    TurnStatusBar(status: status) {
                        model.sendInput(sessionId, Data([0x03]))
                    }
                }
                if let pending {
                    MobileChatPromptCard(
                        prompt: pending,
                        maxHeight: geo.size.height * 0.45,
                        onApproval: { optionId in
                            model.respondPrompt(sessionId, itemId: pending.itemId, revision: pending.revision, optionId: optionId)
                        },
                        onQuestion: { selections in
                            model.respondPromptSelections(sessionId, itemId: pending.itemId, revision: pending.revision, selections: selections)
                        }
                    )
                    // Her pending prompt için taze @State (seçim/free-text/sending sızmasın);
                    // art arda farklı prompt'larda bayat seçim/takılı buton olmaz.
                    .id(pending.itemId)
                }
                composer
            }
        }
        .padding(.bottom, keyboard.height)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeOut(duration: 0.25), value: keyboard.height)
        .task(id: sessionId) { model.subscribeChat(sessionId) }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                TextField("Mesaj…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button {
                    guard !draft.isEmpty else { return }
                    // Metni yaz → settle → Enter'ı AYRI yolla (submitText). Tek
                    // write'taki birleşik `metin\r` Claude TUI'sinde submit olmaz.
                    model.submitText(sessionId, draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large)
                }
                .disabled(draft.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
    }
}
