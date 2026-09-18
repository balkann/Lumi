// LumiMobile/App/MobileHeuristicQuestionCard.swift
import SwiftUI
import LumiMobileKit

/// AI'ın metinde sunduğu seçenekleri tıklanabilir düğmeler olarak gösterir
/// (orca heuristic yolu). Tek-seçim: dokun → hemen gönder. Çok-seçim: işaretle
/// → Gönder. Cevap normal chat mesajı olarak gider (stream-json'da AskUserQuestion
/// tool'u yok; seçenek metni yanıt olur).
struct MobileHeuristicQuestionCard: View {
    let question: ChatHeuristicQuestion
    let onAnswer: ([Int]) -> Void

    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.question.isEmpty {
                Text(question.question)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    if question.multiSelect {
                        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                    } else {
                        onAnswer([index])
                    }
                } label: {
                    HStack(spacing: 8) {
                        if question.multiSelect {
                            Image(systemName: selected.contains(index) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(index) ? Color.accentColor : .secondary)
                        }
                        Text(option)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            if question.multiSelect {
                Button {
                    onAnswer(question.options.indices.filter { selected.contains($0) }.sorted())
                } label: {
                    Text("Gönder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
