import XCTest
import LumiWire
@testable import LumiMobileKit

final class ChatTranscriptTests: XCTestCase {

    private func assistant(_ id: String, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, blocks: [.text(text, presentation: nil)],
                    timestampMs: nil, turnId: nil)
    }
    private func user(_ id: String, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: .user, blocks: [.text(text, presentation: nil)],
                    timestampMs: nil, turnId: nil)
    }

    // MARK: streaming gate

    /// Yanıt akarken (henüz transcript'e düşmemiş) → metin görünür.
    func testStreamingShowsWhileNoRealMessage() {
        var gate = ChatStreamGate()
        let prev = [assistant("a1", "önceki cevap")]
        let (g1, s1) = chatDeriveStreaming(gate: gate, folded: prev, incoming: "Merhab")
        gate = g1
        XCTAssertEqual(s1, "Merhab")
        let (g2, s2) = chatDeriveStreaming(gate: gate, folded: prev, incoming: "Merhaba dünya")
        gate = g2
        XCTAssertEqual(s2, "Merhaba dünya")
    }

    /// Gerçek mesaj transcript'e düşünce (tail assistant metinle önden gidiyor +
    /// segment başından beri taşındı) → balon gizlenir (nil), gerçek mesaj kalır.
    func testStreamingHidesWhenRealMessageLands() {
        var gate = ChatStreamGate()
        let prev = [assistant("a1", "önceki")]
        let (g1, _) = chatDeriveStreaming(gate: gate, folded: prev, incoming: "Merhaba dünya")
        gate = g1
        // Yanıt landi: yeni assistant mesajı tail oldu, metinle başlıyor.
        let landed = prev + [assistant("a2", "Merhaba dünya!")]
        let (g2, s2) = chatDeriveStreaming(gate: gate, folded: landed, incoming: nil)
        gate = g2
        XCTAssertNil(s2, "gerçek mesaj düşünce streaming balonu gizlenmeli")
    }

    /// KRİTİK (kullanıcı şikâyeti): yanıt transcript'e HİÇ düşmese ve Mac
    /// streamingText'i null'a çekse bile metin EKRANDAN SİLİNMEMELİ.
    func testStreamingPersistsWhenTurnEndsButNoRealMessage() {
        var gate = ChatStreamGate()
        let prev = [assistant("a1", "önceki")]
        let (g1, _) = chatDeriveStreaming(gate: gate, folded: prev, incoming: "Cevap metni")
        gate = g1
        // Turn bitti: Mac streamingText=nil yolladı, ama yeni mesaj gelmedi.
        let (g2, s2) = chatDeriveStreaming(gate: gate, folded: prev, incoming: nil)
        gate = g2
        XCTAssertEqual(s2, "Cevap metni", "yeni mesaj yokken streaming metni tutulmalı (vanish yok)")
    }

    /// Yeni segment (önceki yanıtın önekini tekrarlamayan yeni metin) yeniden çıpalar.
    func testNewSegmentReanchors() {
        var gate = ChatStreamGate()
        let base = [assistant("a1", "ilk")]
        let (g1, _) = chatDeriveStreaming(gate: gate, folded: base, incoming: "ilk yanıt")
        gate = g1
        let landed = base + [assistant("a2", "ilk yanıt")]
        let (g2, s2) = chatDeriveStreaming(gate: gate, folded: landed, incoming: nil)
        gate = g2
        XCTAssertNil(s2)
        // Yeni turn başlar: farklı metin → yeni balon görünür.
        let (g3, s3) = chatDeriveStreaming(gate: gate, folded: landed, incoming: "ikinci")
        gate = g3
        XCTAssertEqual(s3, "ikinci")
    }

    // MARK: pending echo

    func testPendingAppendComputesExpectedOccurrence() {
        var pend: [ChatPending] = []
        pend = chatPendingAppend(current: pend, id: "p1", text: "selam",
                                 baselineOccurrences: 0, baselineTailMessageId: "a1")
        XCTAssertEqual(pend.first?.expectedOccurrence, 1)
        // Aynı metni tekrar gönder (henüz landmadı) → 2. beklenir.
        pend = chatPendingAppend(current: pend, id: "p2", text: "selam",
                                 baselineOccurrences: 0, baselineTailMessageId: "a1")
        XCTAssertEqual(pend.last?.expectedOccurrence, 2)
    }

    func testPendingRetiredWhenTranscriptEchoesText() {
        var pend = chatPendingAppend(current: [], id: "p1", text: "selam",
                                     baselineOccurrences: 0, baselineTailMessageId: "a1")
        // Transcript'e user "selam" düştü → emekliye ayrılır.
        let msgs = [assistant("a1", "..."), user("u1", "selam")]
        pend = chatRetireLandedPending(messages: msgs, current: pend)
        XCTAssertTrue(pend.isEmpty, "transcript metni yankılayınca pending kalkmalı")
    }

    func testPendingKeptWhenNoTranscriptEcho() {
        // stream-json kullanıcı mesajını yankılamıyorsa pending KALIR (kalıcı gösterim).
        let pend = chatPendingAppend(current: [], id: "p1", text: "selam",
                                     baselineOccurrences: 0, baselineTailMessageId: "a1")
        let msgs = [assistant("a1", "cevap")]
        let after = chatRetireLandedPending(messages: msgs, current: pend)
        XCTAssertEqual(after.count, 1, "yankı yoksa kullanıcı mesajı ekranda kalmalı")
    }

    // MARK: assemble

    func testAssembleAnchorsPendingAfterBaselineAndStreamingAtEnd() {
        let messages = [assistant("a1", "önceki cevap")]
        let pending = [ChatPending(id: "p1", text: "sorum", expectedOccurrence: 1,
                                   baselineTailMessageId: "a1")]
        let data = chatAssembleRenderMessages(messages: messages, pending: pending,
                                              streaming: "yanıt yazılıyor")
        XCTAssertEqual(data.map(\.id), ["a1", "p1", "streaming"])
        XCTAssertEqual(data[1].role, .user)
        XCTAssertEqual(data[2].role, .assistant)
    }

    func testAssembleLeadingWhenNoBaselineAndTrailingWhenBaselineMissing() {
        // baseline nil → başta
        let d1 = chatAssembleRenderMessages(messages: [], pending: [
            ChatPending(id: "p1", text: "ilk mesaj", expectedOccurrence: 1, baselineTailMessageId: nil)
        ], streaming: nil)
        XCTAssertEqual(d1.map(\.id), ["p1"])
        // baseline mesajı listede yok → sonda
        let d2 = chatAssembleRenderMessages(messages: [assistant("a1", "x")], pending: [
            ChatPending(id: "p2", text: "geç", expectedOccurrence: 1, baselineTailMessageId: "yok")
        ], streaming: nil)
        XCTAssertEqual(d2.map(\.id), ["a1", "p2"])
    }
}
