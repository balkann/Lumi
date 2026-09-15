// LumiMobile/App/MobileChatToolRunView.swift
import SwiftUI
import LumiMobileKit

/// Katlanmış araç aktivitesi: "🔧 3 işlem" satırı; tap → tool-call/result detayları.
struct MobileChatToolRunView: View {
    let activity: [ChatMessage]
    @State private var expanded = false

    var body: some View {
        if !activity.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption2)
                        Text("\(toolCount) işlem")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(activity) { message in
                        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                            toolLine(block)
                        }
                    }
                    .padding(.leading, 18)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var toolCount: Int {
        activity.reduce(0) { total, m in
            total + m.blocks.filter { if case .toolCall = $0 { return true } else { return false } }.count
        }
    }

    @ViewBuilder
    private func toolLine(_ block: ChatBlock) -> some View {
        switch block {
        case let .toolCall(name, inputPreview, _):
            Text("▶ \(name) \(inputPreview)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case let .toolResult(output, isError):
            Text(output)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(isError ? .red : .secondary)
                .lineLimit(6)
        default:
            EmptyView()
        }
    }
}
