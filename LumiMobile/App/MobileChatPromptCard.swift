import SwiftUI
import LumiMobileKit
import LumiWire

/// Faz 3 / 3.1: composer üstünde etkileşimli prompt kartı. En son pending item'ı çizer.
/// approval: title+detail + Allow(mavi)/Deny(/don't-ask). question: tek-seçim tap; multiSelect
/// toggle+Submit; allowOther free-text. Gruplu çok-soru (questions.count>1) = Faz 3.1 Task 8.
struct MobileChatPromptCard: View {
    let prompt: ChatPrompt
    let onApproval: (String) -> Void                                   // optionId
    let onQuestion: ([(indices: [Int], other: String?)]) -> Void       // tek soru: [ (indices, other) ]
    @State private var sending = false
    @State private var selected: [Int] = []
    @State private var freeText = ""

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: prompt.kind == .approval ? "shield.lefthalf.filled" : "questionmark.circle")
                    Text(prompt.kind == .question && prompt.questions.count > 1 ? prompt.questions[0].question : prompt.title)
                        .font(.footnote.bold())
                }
                if let detail = prompt.detail, !detail.isEmpty {
                    Text(detail).font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                switch prompt.kind {
                case .approval: approvalButtons
                case .question:
                    if prompt.questions.count > 1 {
                        Text("Bu çok-soru grubu telefonda henüz desteklenmiyor (Mac'ten cevaplayın).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        questionBody
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
    }

    // MARK: approval

    private var approvalButtons: some View {
        ForEach(Array(prompt.options.enumerated()), id: \.element.id) { idx, opt in
            optionButton(opt.label, description: opt.description, primary: idx == 0) {
                guard !sending else { return }
                sending = true
                onApproval(opt.id)
            }
        }
    }

    // MARK: question (tek soru)

    @ViewBuilder private var questionBody: some View {
        ForEach(Array(prompt.options.enumerated()), id: \.element.id) { idx, opt in
            optionButton(opt.label, description: opt.description,
                         primary: false, checked: prompt.multiSelect ? selected.contains(idx) : nil) {
                if prompt.multiSelect {
                    if let at = selected.firstIndex(of: idx) { selected.remove(at: at) } else { selected.append(idx) }
                } else {
                    guard !sending else { return }
                    sending = true
                    onQuestion([(indices: [idx], other: nil)])
                }
            }
        }
        if prompt.multiSelect {
            Button {
                guard !sending, !selected.isEmpty else { return }
                sending = true
                onQuestion([(indices: selected.sorted(), other: trimmedOther)])
            } label: {
                Text("Gönder\(selected.isEmpty ? "" : " (\(selected.count))")")
                    .font(.footnote.bold()).frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(selected.isEmpty ? 0.08 : 0.22),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .disabled(sending || selected.isEmpty)
        }
        if prompt.allowOther { freeTextRow }
    }

    private var freeTextRow: some View {
        HStack(spacing: 6) {
            TextField("Ya da yaz…", text: $freeText, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            Button {
                guard !sending, !trimmedOtherIsEmpty else { return }
                sending = true
                onQuestion([(indices: prompt.multiSelect ? selected.sorted() : [], other: trimmedOther)])
            } label: { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                .disabled(sending || trimmedOtherIsEmpty)
        }
    }

    // MARK: helpers

    private var trimmedOther: String? {
        let t = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    private var trimmedOtherIsEmpty: Bool { trimmedOther == nil }

    @ViewBuilder
    private func optionButton(_ label: String, description: String?, primary: Bool,
                              checked: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let checked { Image(systemName: checked ? "checkmark.square.fill" : "square") }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.footnote.bold())
                    if let d = description { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(primary ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .disabled(sending)
    }
}
