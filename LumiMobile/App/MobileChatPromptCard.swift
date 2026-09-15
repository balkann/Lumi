import SwiftUI
import LumiMobileKit

/// Faz 3: composer üstünde etkileşimli prompt kartı. En son pending item'ı çizer.
/// approval: title+detail + Allow(mavi)/Deny. question: soru + tek-seçim satırları.
struct MobileChatPromptCard: View {
    let prompt: ChatPrompt
    let onRespond: (String) -> Void   // optionId
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: prompt.kind == .approval ? "shield.lefthalf.filled" : "questionmark.circle")
                    Text(prompt.title).font(.footnote.bold())
                }
                if let detail = prompt.detail, !detail.isEmpty {
                    Text(detail).font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                ForEach(Array(prompt.options.enumerated()), id: \.element.id) { idx, opt in
                    Button {
                        guard !sending else { return }
                        sending = true
                        onRespond(opt.id)
                    } label: {
                        HStack {
                            Text(opt.label).font(.footnote.bold())
                            if let d = opt.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(idx == 0 ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(sending)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
    }
}
