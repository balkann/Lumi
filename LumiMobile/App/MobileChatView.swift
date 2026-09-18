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
    @FocusState private var composerFocused: Bool

    // Birleşik render listesi (orca): optimistic pending + journal mesajları +
    // gated streaming balonu → tek liste, sonra turn'lere katlanır. Streaming
    // artık ayrı bir blok DEĞİL; listenin içinde sentetik assistant turn'ü —
    // gerçek mesaj düşene kadar kalır (turn bitince silinmez).
    private var turns: [FoldedTurn] { foldChatMessages(model.chatRenderMessages(sessionId)) }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if turns.isEmpty {
                                // Faz 2.1: chat oturumu artık yalnız kind=chat için açılıyor
                                // (TerminalSessionView tür yönlendirmesi). Boş chat = "henüz
                                // mesaj yok" → yanıltıcı "yükleniyor" yerine eyleme çağıran metin.
                                Text("Sohbet boş — aşağıya yazıp başlat.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }
                            ForEach(turns) { turn in
                                MobileChatMessageView(turn: turn).id(turn.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: turns.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    // Streaming metni büyüdükçe de dibe kaydır (token akışı sırasında).
                    .onChange(of: model.gatedStreaming[sessionId]) { _, _ in
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
                } else if let hq = model.heuristicQuestion(sessionId) {
                    // Hook prompt'u yoksa: AI'ın metindeki seçeneklerini tıklanabilir kart yap.
                    MobileHeuristicQuestionCard(question: hq) { indexes in
                        model.answerHeuristicQuestion(sessionId, hq, selectedIndexes: indexes)
                    }
                    // Farklı soru → taze seçim state'i.
                    .id(hq.options.joined(separator: "|"))
                }
                composer
            }
        }
        .padding(.bottom, keyboard.height)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeOut(duration: 0.25), value: keyboard.height)
        .task(id: sessionId) { model.subscribeChat(sessionId) }
        // Boş chat açılışında composer'a odaklan → "ne yapmalıyım" belirsizliği
        // kalkar, kullanıcı hemen yazmaya başlar (Faz 2.1 §4).
        .onAppear { if turns.isEmpty { composerFocused = true } }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                TextField("Mesaj…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($composerFocused)
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
