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
    // Gruplu çok-soru state (Bileşen D)
    @State private var groupSel: [Int: [Int]] = [:]
    @State private var groupText: [Int: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView {
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
                            groupedQuestionBody
                        } else {
                            questionBody
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.45)
            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: grouped question (çok-soru; Bileşen D)

    @ViewBuilder private var groupedQuestionBody: some View {
        ForEach(Array(prompt.questions.enumerated()), id: \.element.id) { qi, q in
            VStack(alignment: .leading, spacing: 4) {
                Text(q.header ?? q.question)
                    .font(.footnote.bold())
                    .padding(.top, qi == 0 ? 0 : 4)
                ForEach(Array(q.options.enumerated()), id: \.element.id) { oi, opt in
                    let isChecked = groupSel[qi]?.contains(oi) ?? false
                    optionButton(opt.label, description: opt.description,
                                 primary: false, checked: q.multiSelect ? isChecked : nil) {
                        if q.multiSelect {
                            var sel = groupSel[qi] ?? []
                            if let at = sel.firstIndex(of: oi) { sel.remove(at: at) } else { sel.append(oi) }
                            groupSel[qi] = sel
                        } else {
                            // Tek-seçim: bir önceki seçimi sil, yenisini yaz.
                            groupSel[qi] = [oi]
                        }
                    }
                }
                if q.allowOther {
                    HStack(spacing: 6) {
                        TextField("Ya da yaz…", text: Binding(
                            get: { groupText[qi] ?? "" },
                            set: { groupText[qi] = $0 }
                        ), axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    }
                }
            }
        }
        // Tek Gönder butonu — tüm soruları sırayla toplar.
        // groupedReady: her soru cevaplanmış olmalı (seçim VEYA dolu free-text).
        let groupedReady = prompt.questions.indices.allSatisfy { qi in
            !(groupSel[qi] ?? []).isEmpty
                || !(groupText[qi] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        Button {
            guard !sending else { return }
            sending = true
            let result = prompt.questions.indices.map { qi -> (indices: [Int], other: String?) in
                let trimmed = groupText[qi]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let other: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
                return (indices: (groupSel[qi] ?? []).sorted(), other: other)
            }
            onQuestion(result)
        } label: {
            Text("Gönder")
                .font(.footnote.bold()).frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(groupedReady ? 0.22 : 0.08),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .disabled(sending || !groupedReady)
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
