// LumiMobile/App/ChatLiveTerminalStrip.swift
import SwiftUI
import UIKit
import LumiMobileKit

/// Chat ekranında turn sürerken görünen salt-okunur canlı terminal alanı
/// (spec 2026-09-17). Ayna emülatörü Mac'in grid'inde kalır (chunk'lar resize
/// taşır); view grid yüksekliğinde çizilip ALTA hizalanarak şerit yüksekliğine
/// kırpılır — en güncel içerik (akan metin, spinner, soru) hep görünür.
struct ChatLiveTerminalStrip: View {
    let model: AppModel
    let sessionId: String
    static let stripHeight: CGFloat = 220

    @State private var buffer = TerminalFeedBuffer()

    private static let lineHeight: CGFloat = UIFont.monospacedSystemFont(
        ofSize: UIFont.systemFontSize, weight: .regular).lineHeight

    /// Grid yüksekliği yaklaşıklaması: rows × mono satır yüksekliği. Birkaç
    /// puntoluk sapma kabul — kırpma alttan hizalı olduğu için içerik kaybolmaz.
    private var gridHeight: CGFloat {
        let rows = model.gridRows[sessionId] ?? 24
        return max(Self.stripHeight, CGFloat(rows) * Self.lineHeight + 4)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Salt-okunur: girişler yok sayılır (MirrorTerminalView zaten
            // first-responder olmaz; şeritten klavye açılmaz).
            TerminalHostView(onInput: { _ in }, buffer: buffer)
                .frame(height: gridHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.stripHeight)
        .clipped()
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .task(id: sessionId) {
            for await chunk in model.terminalStream(sessionId) {
                buffer.feed(chunk)
            }
        }
    }
}
