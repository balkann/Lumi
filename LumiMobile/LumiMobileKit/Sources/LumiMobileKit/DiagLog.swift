import Foundation

/// Kalıcı teşhis günlüğü: satır-tabanlı, boyut-tavanlı (tek `.old` rotasyonu).
///
/// LumiPackages/LumiKit'teki DiagLog'un iOS kopyası (paketler bağımsız — kod
/// ikizi bilinçli). Cihazda Documents/lumi-mobile.log'a yazar; Mac'ten
/// `xcrun devicectl device copy from` ile çekilip incelenir. Yazım serial
/// queue'da asenkrondur; olay-frekanslı çağrılar içindir, sıcak yollarda
/// KULLANMA. `configure` edilmemiş logger sessiz no-op'tur.
public final class DiagLog: @unchecked Sendable {
    public static let shared = DiagLog()

    // Tüm mutable durum `queue`'ya confined — @unchecked Sendable sözleşmesi.
    private let queue = DispatchQueue(label: "lumi.diaglog", qos: .utility)
    private var fileURL: URL?
    private var maxBytes = 2_000_000
    private let formatter: ISO8601DateFormatter

    public init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    public func configure(directory: URL, filename: String, maxBytes: Int = 2_000_000) {
        queue.async {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent(filename)
            self.maxBytes = maxBytes
        }
    }

    public func log(_ category: String, _ message: String) {
        let stamp = formatter.string(from: Date())
        queue.async {
            self.append("\(stamp) [\(category)] \(message)\n")
        }
    }

    /// Bekleyen yazımların bitmesini bloklayarak bekler (test senkronizasyonu).
    public func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        guard let url = fileURL else { return }
        let data = Data(line.utf8)
        let manager = FileManager.default
        if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
           size + data.count > maxBytes {
            let old = url.appendingPathExtension("old")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
