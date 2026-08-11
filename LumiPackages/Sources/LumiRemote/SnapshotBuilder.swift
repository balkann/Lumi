import Foundation
import LumiKit

/// Telefon-yönelik durum özetini üretir (spec §4.2). Saf — I/O yok.
enum SnapshotBuilder {
    static func snapshot(
        terminals: [TerminalMeta],
        repos: [Repo],
        personas: [Persona],
        awaitingDecision: [TerminalID: Bool] = [:],
        currentModel: [TerminalID: String] = [:],
        activePrompts: [TerminalID: DetectedPrompt] = [:]
    ) -> [String: Any] {
        let repoNames = Dictionary(repos.map { ($0.path, $0.name) },
                                   uniquingKeysWith: { first, _ in first })
        let sessions: [[String: Any]] = terminals.map { meta in
            var entry: [String: Any] = [
                "id": meta.id.description,
                "repoPath": meta.repoPath,
                "repoName": repoNames[meta.repoPath]
                    ?? (meta.repoPath as NSString).lastPathComponent,
                "status": meta.status.rawValue,
            ]
            if let title = meta.oscTitle { entry["title"] = title }
            if awaitingDecision[meta.id] == true { entry["awaitingDecision"] = true }
            if let model = currentModel[meta.id] { entry["model"] = model }
            if let prompt = activePrompts[meta.id] {
                entry["activePrompt"] = [questionDict(prompt)]
            }
            return entry
        }
        return [
            "sessions": sessions,
            "repos": repos.map { ["name": $0.name, "path": $0.path] },
            "personas": personas.map { ["id": $0.id, "label": $0.label] },
        ]
    }

    static func awaitingDecisionEvent(sessionId: String, awaiting: Bool) -> [String: Any] {
        ["kind": "awaiting_decision", "sessionId": sessionId, "awaiting": awaiting]
    }

    /// Ekran-scrape prompt'unu mevcut mobil `question` transcript olayına çevirir.
    /// prompt == nil → boş `questions: []` = telefonda kartı temizle (spec 4).
    static func promptEvent(sessionId: String, prompt: DetectedPrompt?) -> [String: Any] {
        let questions: [[String: Any]] = prompt.map { [questionDict($0)] } ?? []
        return ["kind": "transcript", "sessionId": sessionId,
                "item": ["itemType": "question", "questions": questions]]
    }

    private static func questionDict(_ prompt: DetectedPrompt) -> [String: Any] {
        ["header": kindLabel(prompt.kind),
         "question": prompt.questionText ?? "",
         "options": prompt.options]
    }

    private static func kindLabel(_ kind: DetectedPrompt.Kind) -> String {
        switch kind {
        case .permission: return "İzin isteği"
        case .question: return "Soru"
        case .generic: return ""
        }
    }

    static func modelChangeEvent(sessionId: String, model: String) -> [String: Any] {
        ["kind": "model_change", "sessionId": sessionId, "model": model]
    }

    /// İzlenen transcript dosyası değişti (ör. /clear): telefon o oturumun feed'ini +
    /// soru kartını sıfırlar; sonraki canlı transcript öğeleri yeni oturumu doldurur (spec 4/clear).
    static func sessionResetEvent(sessionId: String) -> [String: Any] {
        ["kind": "session_reset", "sessionId": sessionId]
    }

    static func statusChangeEvent(
        meta: TerminalMeta,
        status: TerminalStatus,
        repoName: String,
        summary: String?
    ) -> [String: Any] {
        var event: [String: Any] = [
            "kind": "status_change",
            "sessionId": meta.id.description,
            "status": status.rawValue,
            "repoName": repoName,
        ]
        if let summary { event["summary"] = summary }
        return event
    }
}
