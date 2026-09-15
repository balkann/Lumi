// LumiMobile/App/MobileChatView.swift
import SwiftUI
import LumiMobileKit

/// Native chat görünümü: transcript'ten türeyen mesajları satır-saran balonlar
/// olarak gösterir (yatay scroll yok). Composer serbest metin gönderir.
struct MobileChatView: View {
    let model: AppModel
    let sessionId: String

    @StateObject private var keyboard = KeyboardObserver()
    @State private var draft = ""

    private var turns: [FoldedTurn] { foldChatMessages(model.chatMessages(sessionId)) }

    var body: some View {
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
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: turns.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            composer
        }
        .padding(.bottom, keyboard.height)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeOut(duration: 0.25), value: keyboard.height)
        .task(id: sessionId) { model.subscribeChat(sessionId) }
        .onDisappear { model.unsubscribe(sessionId) }
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
                    model.sendInput(sessionId, Data((draft + "\r").utf8))
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
