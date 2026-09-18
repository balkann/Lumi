import Foundation
import LumiWire

// Orca'nın mobil chat render mantığının Swift portu (kaynak:
// orca `mobile/src/session/mobile-native-chat-{streaming-gate,pending-echo,
// pending-retirement,render-data}.ts`). İki davranışı birebir kopyalar:
//   1. Canlı streaming metni turn bitince EKRANDAN SİLİNMEZ — gerçek transcript
//      mesajı listeye düşene kadar sentetik balon olarak kalır (orca "caught-up"
//      geçidi). Mac streamingText'i null'a çekse bile telefon metni TUTAR ve
//      yalnız transcript tail metinle "önden gidince" gizler.
//   2. Kullanıcının kendi gönderdiği mesaj ANINDA görünür (optimistic echo,
//      client-side; sunucu onayı beklenmez). Transcript metni yankıladığında
//      (varsa) sayım-tabanlı dedup ile emekliye ayrılır.
// Orca'nın görüntü/çoklu-sekme/glue-run uç durumları bu fazın kapsamı dışında
// (tek oturum, görüntüsüz) — kasıtlı olarak alınmadı.

// MARK: - Metin normalizasyonu (orca normalizeReconcileText / normalizedUserText)

/// Kontrol karakterlerini atar, kırpar, ardışık boşlukları tek boşluğa indirger.
public func normalizeChatUserText(_ text: String) -> String {
    let noControls = String(text.unicodeScalars.filter { scalar in
        // ANSI/terminal kontrol karakterlerini (C0, DEL) düşür; \n \t normal boşluğa katlanır.
        scalar.value >= 0x20 || scalar == " " || scalar == "\n" || scalar == "\t"
    })
    let parts = noControls.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
    return parts.joined(separator: " ")
}

/// Bir user mesajının normalize metni (assistant/diğer → nil).
public func normalizedChatUserText(_ message: ChatMessage) -> String? {
    guard message.role == .user else { return nil }
    let joined = message.blocks.compactMap { block -> String? in
        if case .text(let t, _) = block { return t } else { return nil }
    }.joined(separator: " ")
    let n = normalizeChatUserText(joined)
    return n.isEmpty ? nil : n
}

// MARK: - Optimistic pending echo (orca pending-echo + pending-retirement)

/// Sunucu onayı beklenmeden listeye eklenen kullanıcı mesajı yankısı.
public struct ChatPending: Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    /// Transcript'te bu metnin KAÇINCI kopyası olduğunda emekliye ayrılacağı.
    public let expectedOccurrence: Int
    /// Gönderim anındaki transcript tail mesaj id'si (echo bu satırdan sonra çizilir).
    public let baselineTailMessageId: String?

    public init(id: String, text: String, expectedOccurrence: Int, baselineTailMessageId: String?) {
        self.id = id
        self.text = text
        self.expectedOccurrence = expectedOccurrence
        self.baselineTailMessageId = baselineTailMessageId
    }
}

/// Yeni pending ekler. expectedOccurrence = transcript'teki mevcut kopya sayısı
/// (baselineOccurrences) + bekleyen aynı-metin yankı sayısı + 1 (orca).
public func chatPendingAppend(current: [ChatPending], id: String, text: String,
                              baselineOccurrences: Int, baselineTailMessageId: String?) -> [ChatPending] {
    let normalized = normalizeChatUserText(text)
    let earlierOutstanding = current.filter {
        normalizeChatUserText($0.text) == normalized && $0.expectedOccurrence > baselineOccurrences
    }.count
    let expected = baselineOccurrences + earlierOutstanding + 1
    return current + [ChatPending(id: id, text: text, expectedOccurrence: expected,
                                  baselineTailMessageId: baselineTailMessageId)]
}

/// Transcript'te aynı metin expectedOccurrence kadar göründüyse pending emekliye
/// ayrılır (orca exact-landing count pass). Glue-run/görüntü dalları alınmadı.
public func chatRetireLandedPending(messages: [ChatMessage], current: [ChatPending]) -> [ChatPending] {
    var landedCounts: [String: Int] = [:]
    for m in messages {
        if let t = normalizedChatUserText(m) { landedCounts[t, default: 0] += 1 }
    }
    return current.filter { p in
        let n = normalizeChatUserText(p.text)
        if n.isEmpty { return true }
        let landed = (landedCounts[n] ?? 0) >= p.expectedOccurrence
        return !landed
    }
}

/// Verilen metnin transcript'teki user-mesajı kopya sayısı (baselineOccurrences).
public func chatCountUserTextOccurrences(_ messages: [ChatMessage], _ normalized: String) -> Int {
    messages.reduce(0) { acc, m in normalizedChatUserText(m) == normalized ? acc + 1 : acc }
}

// MARK: - Streaming geçidi (orca deriveMobileNativeChatStreaming + hold uyarlaması)

/// Streaming balonu geçidi. `hold`, Mac streamingText'i null'a çekse bile metni
/// TUTAR (Lumi tek-kaynak journal boru hattı: append ile null yarışında metin
/// kaybolmasın) — orca'nın "yalnız transcript tail metinle önden gidince gizle"
/// ruhu. baselineTailId: segment başındaki tail; gerçek yanıt eski özdeş bir
/// turn'ün önekini tekrarlarsa balonu yanlışlıkla gizlememek için.
public struct ChatStreamGate: Sendable, Equatable {
    public var prevText: String
    public var baselineTailId: String?
    public var hold: String?
    public init(prevText: String = "", baselineTailId: String? = nil, hold: String? = nil) {
        self.prevText = prevText
        self.baselineTailId = baselineTailId
        self.hold = hold
    }
}

private func assistantTailText(_ tail: ChatMessage?) -> String {
    guard let tail, tail.role == .assistant else { return "" }
    return tail.blocks.compactMap { block -> String? in
        if case .text(let t, _) = block { return t } else { return nil }
    }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Geçidi bir tık ilerletir ve görünür streaming metnini döndürür (nil = gizle).
/// `folded`: journal mesajlarının katlanmış hali (tool satırları katlanmış).
/// `incoming`: bu tıktaki ham streaming metni (Mac chat_status); yalnız mesaj
/// değişince çağrıldıysa nil geçilir (hold korunur, catch-up yeniden bakılır).
public func chatDeriveStreaming(gate: ChatStreamGate, folded: [ChatMessage],
                                incoming: String?) -> (gate: ChatStreamGate, streaming: String?) {
    var g = gate
    let text = (incoming ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let tailId = folded.last?.id

    if !text.isEmpty {
        // prevText'i uzatmıyorsa yeni segment (yeni yanıt parçası) → tail'i yeniden çıpala.
        let segmentStart = !g.prevText.isEmpty && !text.hasPrefix(g.prevText)
        if segmentStart || g.prevText.isEmpty {
            g.baselineTailId = tailId
        }
        g.prevText = text
        g.hold = text
    }

    guard let display = g.hold, !display.isEmpty else {
        return (g, nil)
    }
    let tailLeads = assistantTailText(folded.last).hasPrefix(display)
    // Gerçek yanıt LANDI: tail metinle önden gidiyor VE segment başından beri taşındı.
    let caughtUp = tailLeads && tailId != g.baselineTailId
    if caughtUp {
        g.hold = nil
        g.prevText = ""
        g.baselineTailId = nil
        return (g, nil)
    }
    return (g, display)
}

// MARK: - Render listesi birleştirme (orca buildMobileNativeChatTransientData)

/// leading pending + (journal mesajları, her birinin ardına çıpalı pending) +
/// streaming balonu + trailing pending. Sentetik mesajlar da normal ChatMessage
/// olduğundan çağıran taraf sonucu `foldChatMessages` ile turn'lere katlar.
public func chatAssembleRenderMessages(messages: [ChatMessage], pending: [ChatPending],
                                       streaming: String?) -> [ChatMessage] {
    let ids = Set(messages.map { $0.id })
    var leading: [ChatMessage] = []
    var trailing: [ChatMessage] = []
    var anchored: [String: [ChatMessage]] = [:]
    for p in pending {
        let bubble = ChatMessage(id: p.id, role: .user,
                                 blocks: [.text(p.text, presentation: nil)],
                                 timestampMs: nil, turnId: nil)
        if let base = p.baselineTailMessageId {
            if ids.contains(base) { anchored[base, default: []].append(bubble) }
            else { trailing.append(bubble) }   // satır henüz gelmedi/katlandı → sonda (yeri korunur)
        } else {
            leading.append(bubble)             // boş chat'e gönderim → başta
        }
    }
    var result: [ChatMessage] = leading
    for m in messages {
        result.append(m)
        if let attached = anchored[m.id] { result.append(contentsOf: attached) }
    }
    if let s = streaming, !s.isEmpty {
        result.append(ChatMessage(id: "streaming", role: .assistant,
                                  blocks: [.text(s, presentation: nil)],
                                  timestampMs: nil, turnId: nil))
    }
    result.append(contentsOf: trailing)
    return result
}
