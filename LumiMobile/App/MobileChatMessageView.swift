// LumiMobile/App/MobileChatMessageView.swift
import SwiftUI
import LumiMobileKit

/// Bir katlanmış turn: sahip mesajın metin balonu + altına katlanmış araç aktivitesi.
struct MobileChatMessageView: View {
    let turn: FoldedTurn

    var body: some View {
        VStack(alignment: turn.message.role == .user ? .trailing : .leading, spacing: 4) {
            ForEach(Array(turn.message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            MobileChatToolRunView(activity: turn.toolActivity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: turn.message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ChatBlock) -> some View {
        switch block {
        case let .text(text, _):
            Text(LocalizedStringKey(text))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(turn.message.role == .user ? Color.white : Color.primary)
                .frame(maxWidth: 300, alignment: turn.message.role == .user ? .trailing : .leading)
        case let .toolCall(name, preview, _):
            Text("▶ \(name) \(preview)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .toolResult(output, isError):
            Text(output)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    private var bubbleColor: Color {
        turn.message.role == .user ? Color.accentColor : Color(uiColor: .secondarySystemBackground)
    }
}
