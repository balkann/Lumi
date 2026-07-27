import Foundation
import LumiKit

/// Telefon-yönelik durum özetini üretir (spec §4.2). Saf — I/O yok.
enum SnapshotBuilder {
    static func snapshot(
        terminals: [TerminalMeta],
        repos: [Repo],
        personas: [Persona]
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
            return entry
        }
        return [
            "sessions": sessions,
            "repos": repos.map { ["name": $0.name, "path": $0.path] },
            "personas": personas.map { ["id": $0.id, "label": $0.label] },
        ]
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
