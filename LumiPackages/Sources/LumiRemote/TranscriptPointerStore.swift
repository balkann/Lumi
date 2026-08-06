import Foundation

/// SessionStart hook'unun yazdığı `<mapDir>/<terminalID>.json` pointer'ından bir
/// terminalin AKTİF transcript dosyasının yolunu okur. Hook her oturum başında
/// (startup/resume/clear/compact/fork) bu dosyayı atomik overwrite eder → pointer
/// her zaman güncel dosyayı gösterir (/clear'da yeni dosya, worktree'de doğru dizin).
/// Saf/senkron okuma; dosya var/yok kararı watcher'a aittir.
struct TranscriptPointerStore: Sendable {
    let mapDir: URL

    init(mapDir: URL) { self.mapDir = mapDir }

    func transcriptPath(for terminalID: String) -> URL? {
        let pointer = mapDir.appendingPathComponent("\(terminalID).json")
        guard let data = try? Data(contentsOf: pointer),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["transcript_path"] as? String, !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
