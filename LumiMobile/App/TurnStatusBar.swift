import SwiftUI
import LumiMobileKit
import Foundation

/// Faz 2: chat composer'ının üstünde canlı turn-status bandı. working iken görünür.
/// Sol: spinner + "Çalışıyor {n}sn" (TimelineView ile canlı). Orta: araç çipi.
/// Sağ: Stop → Ctrl-C (0x03).
struct TurnStatusBar: View {
    let status: ChatTurnStatus
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedLabel(now: context.date))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let tool = status.tool {
                    Text(tool)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Button("Durdur", role: .destructive) { onStop() }
                    .font(.footnote.bold())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .systemBackground))
        }
    }

    private func elapsedLabel(now: Date) -> String {
        guard let startedAtMs = status.startedAtMs else { return "Çalışıyor" }
        let started = Date(timeIntervalSince1970: Double(startedAtMs) / 1000)
        let secs = max(0, Int(now.timeIntervalSince(started)))
        return "Çalışıyor \(secs)sn"
    }
}
