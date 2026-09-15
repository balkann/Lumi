import Foundation

/// Saf, test-edilebilir etkileşimli-prompt reducer (spec §4.3). Session başına bir örnek;
/// hook olaylarını `ChatPrompt` item'larına katlar. Faz 3.0: izin + tek-soru tek-seçim.
public final class PromptJournal {
    private let seq: () -> Int
    public private(set) var items: [ChatPrompt] = []

    public init(seq: @escaping () -> Int = { 0 }) { self.seq = seq }

    /// Değişen (yeni/güncellenen/iptal) item'ları döndürür; değişiklik yoksa boş.
    public func reduce(_ event: AgentHookEvent) -> [ChatPrompt] {
        switch event.kind {
        case .preToolUse where event.isUserQuestionTool && event.isLead:
            guard let p = makeQuestion(event) else { return [] }
            return upsert(p)
        case .permissionRequest where event.isLead:
            guard let p = makeApproval(event) else { return [] }
            return upsert(p)
        case .postToolUse, .postToolUseFailure:
            guard event.isLead, let id = event.toolUseID else { return [] }
            return cancel(where: { $0.itemId == id })
        case .stop, .stopFailure:
            guard event.isLead else { return [] }
            return cancel(where: { $0.state == .pending })
        case .sessionStart where event.source == "clear":
            // /clear: pending item'ları cancelled olarak yayınla (telefon kartı düşsün),
            // sonra journal'ı sıfırla. Abone değilken yayın olmaz ama journal temizlenir.
            let cancelled = items.filter { $0.state == .pending }.map { item -> ChatPrompt in
                var c = item; c.state = .cancelled; c.revision += 1; return c
            }
            items.removeAll()
            return cancelled
        default:
            return []
        }
    }

    /// Bir item'ı resolved yapar (revision+1). Güncellenen item'ı döndürür (yoksa/
    /// zaten çözülmüşse nil) — `reduce` ile tutarlı API. Cevap actuation sonrası çağrılır.
    @discardableResult
    public func resolve(itemId: String, optionId: String) -> ChatPrompt? {
        guard let idx = items.firstIndex(where: { $0.itemId == itemId }),
              items[idx].state == .pending else { return nil }
        items[idx].state = .resolved
        items[idx].selectedOptionId = optionId
        items[idx].revision += 1
        return items[idx]
    }

    private func itemId(_ event: AgentHookEvent) -> String { event.toolUseID ?? "item-\(seq())" }

    private func makeQuestion(_ event: AgentHookEvent) -> ChatPrompt? {
        guard let obj = parse(event.toolInput),
              let questions = obj["questions"] as? [[String: Any]],
              let q0 = questions.first,
              let question = q0["question"] as? String else { return nil }
        let rawOptions = (q0["options"] as? [[String: Any]]) ?? []
        let options = rawOptions.enumerated().compactMap { (i, o) -> ChatPromptOption? in
            guard let label = o["label"] as? String else { return nil }
            return ChatPromptOption(id: "opt-\(i)", label: label, description: o["description"] as? String)
        }
        guard !options.isEmpty else { return nil }
        return ChatPrompt(itemId: itemId(event), revision: 0, kind: .question, title: question,
                          detail: nil, options: options, state: .pending, selectedOptionId: nil)
    }

    private func makeApproval(_ event: AgentHookEvent) -> ChatPrompt? {
        let tool = event.toolName ?? "araç"
        let detail = event.toolInput.flatMap { summarize($0) }
        let options = [ChatPromptOption(id: "allow", label: "Allow", description: nil),
                       ChatPromptOption(id: "deny", label: "Deny", description: nil)]
        return ChatPrompt(itemId: itemId(event), revision: 0, kind: .approval,
                          title: "\(tool) çalıştırılsın mı?", detail: detail,
                          options: options, state: .pending, selectedOptionId: nil)
    }

    /// itemId ile ekle/güncelle; içerik değişmediyse boş dön (idempotent).
    private func upsert(_ p: ChatPrompt) -> [ChatPrompt] {
        if let idx = items.firstIndex(where: { $0.itemId == p.itemId }) {
            var existing = items[idx]
            if existing.kind == p.kind && existing.title == p.title
                && existing.options == p.options && existing.state == p.state { return [] }
            existing.kind = p.kind; existing.title = p.title; existing.detail = p.detail
            existing.options = p.options; existing.state = p.state; existing.revision += 1
            items[idx] = existing
            return [existing]
        }
        items.append(p)
        return [p]
    }

    private func cancel(where match: (ChatPrompt) -> Bool) -> [ChatPrompt] {
        var changed: [ChatPrompt] = []
        for idx in items.indices where items[idx].state == .pending && match(items[idx]) {
            items[idx].state = .cancelled
            items[idx].revision += 1
            changed.append(items[idx])
        }
        return changed
    }

    private func parse(_ s: String?) -> [String: Any]? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func summarize(_ input: String) -> String? {
        guard let obj = parse(input) else { return input.count <= 120 ? input : nil }
        if let cmd = obj["command"] as? String { return cmd }
        if let path = obj["file_path"] as? String { return path }
        return nil
    }
}
