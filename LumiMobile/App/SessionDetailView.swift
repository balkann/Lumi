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
        .navigationTitle(model.session(sessionId)?.repoName ?? "Oturum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session = model.session(sessionId) {
                    StatusBadge(badge: session.status.badge)
                }
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
                        FeedEntryView(entry: entry).id(entry.id)
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
            TextField(model.macOnline ? "Mesaj yaz…" : "Mac çevrimdışı", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.macOnline)
            Button {
                let text = draft
                draft = ""
                Task { await model.sendText(sessionId: sessionId, text: text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(!model.macOnline || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct FeedEntryView: View {
    let entry: FeedEntry

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
            } else {
                Text("Oturum girdi bekliyor")
                    .font(.subheadline.weight(.semibold))
                if let context = card.context {
                    Text(context).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    ForEach(["1", "2", "3"], id: \.self) { key in
                        Button(key) { onKey(key) }.buttonStyle(.bordered)
                    }
                }
            }
            HStack {
                Button("Enter") { onKey("enter") }.buttonStyle(.borderedProminent)
                Button("Esc") { onKey("esc") }.buttonStyle(.bordered)
            }
        }
        .disabled(disabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)), alignment: .top)
    }
}
