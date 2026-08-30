import SwiftUI
import LumiMobileKit

struct SessionDetailView: View {
    let model: AppModel
    let sessionId: String
    @State private var draft = ""

    private var feed: [FeedEntry] { model.feeds[sessionId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            feedScroll
            if let error = model.lastCommandError[sessionId] {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let card = model.questionCard(for: sessionId) {
                QuestionCardView(card: card, disabled: !model.macOnline) { key in
                    Task { await model.pressKey(sessionId: sessionId, key: key) }
                }
            }
            inputBar
        }
        .task(id: sessionId) { await model.requestHistory(sessionId: sessionId) }
        .navigationTitle(model.session(sessionId)?.repoName ?? "Oturum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session = model.session(sessionId) {
                    StatusBadge(badge: session.status.badge)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Opus") { Task { await model.setModel(sessionId: sessionId, model: "opus") } }
                    Button("Sonnet") { Task { await model.setModel(sessionId: sessionId, model: "sonnet") } }
                    Button("Haiku") { Task { await model.setModel(sessionId: sessionId, model: "haiku") } }
                    Button("Default") { Task { await model.setModel(sessionId: sessionId, model: "default") } }
                } label: {
                    if let raw = model.currentModel(for: sessionId) {
                        Text(model.modelLabel(raw))
                    } else {
                        Image(systemName: "cpu")
                    }
                }
                .disabled(!model.macOnline)
                .accessibilityIdentifier("modelMenu")
            }
        }
    }

    private var feedScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if feed.isEmpty {
                        // Eşleşmeyen oturum (Codex / jsonl yok) — tanımlı davranış (tasarım §5).
                        Text("Bu oturum için zengin akış yok; durum ve metin gönderme çalışır.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(feed) { entry in
                        FeedEntryView(entry: entry, onRetry: retryClosure(for: entry))
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: feed.last?.id) { _, lastId in
                if let lastId {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
            .onAppear {
                if let lastId = feed.last?.id { proxy.scrollTo(lastId, anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(model.macOnline ? "Mesaj yaz…" : "Mac çevrimdışı", text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(!model.macOnline)
                .accessibilityIdentifier("messageField")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .accessibilityIdentifier("sendButton")
            .disabled(!model.macOnline || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await model.sendText(sessionId: sessionId, text: text) }
    }

    private func retryClosure(for entry: FeedEntry) -> (() -> Void)? {
        guard case .userMessage(_, .failed) = entry.item else { return nil }
        return { Task { await model.retrySend(sessionId: sessionId, entryId: entry.id) } }
    }
}

struct FeedEntryView: View {
    let entry: FeedEntry
    var onRetry: (() -> Void)? = nil

    var body: some View {
        switch entry.item {
        case .assistantText(let text):
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolUse(let tool, let summary):
            Label("\(tool): \(summary)", systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .turnDone:
            Divider().padding(.vertical, 2)
        case .question:
            // Sorular akışta değil sabit kartta gösterilir (AppModel bunları feed'e koymaz).
            EmptyView()
        case .userMessage(let text, let status):
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 40)
                Text(text)
                    .font(.body)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                sendStatusIcon(status)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func sendStatusIcon(_ status: SendStatus) -> some View {
        switch status {
        case .sending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Button { onRetry?() } label: {
                Image(systemName: "exclamationmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.red)
            .accessibilityLabel("Tekrar gönder")
        }
    }
}

struct QuestionCardView: View {
    let card: QuestionCard
    let disabled: Bool
    let onKey: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = card.questions?.first {
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(question.question).font(.subheadline)
                ForEach(Array(question.options.prefix(3).enumerated()), id: \.offset) { index, option in
                    Button {
                        onKey("\(index + 1)")
                    } label: {
                        Text("\(index + 1). \(option)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                enterEscRow
            } else if card.isPermission {
                Text("İzin isteği")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                if let context = card.context {
                    Text(context)
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                permissionButton("1", "Evet")
                permissionButton("2", "Evet, bir daha sorma")
                permissionButton("3", "Hayır")
                Button("Esc") { onKey("esc") }.buttonStyle(.bordered)
            } else {
                Text("Oturum girdi bekliyor")
                    .font(.subheadline.weight(.semibold))
                if let context = card.context {
                    Text(context)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    ForEach(["1", "2", "3"], id: \.self) { key in
                        Button(key) { onKey(key) }.buttonStyle(.bordered)
                    }
                }
                enterEscRow
            }
        }
        .disabled(disabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)), alignment: .top)
    }

    private func permissionButton(_ key: String, _ label: String) -> some View {
        Button {
            onKey(key)
        } label: {
            Text("\(key) · \(label)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private var enterEscRow: some View {
        HStack {
            Button("Enter") { onKey("enter") }.buttonStyle(.borderedProminent)
            Button("Esc") { onKey("esc") }.buttonStyle(.bordered)
        }
    }
}
