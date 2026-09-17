/// Uzun-yaşayan pipe tabanlı child süreç soyutlaması (spec §A).
/// PTY değil — saf pipe I/O; satır-sınırlı stdout `AsyncStream`, stdin `write(_:)`.
public protocol StreamingProcessHandle: Sendable {
    /// stdout satır akışı (her eleman bir satır, newline çıkarılmış).
    var lines: AsyncStream<String> { get }
    /// stdin'e yaz (metin verildiği gibi; newline eklemek çağıranın sorumluluğu).
    func write(_ text: String)
    /// Süreci sonlandır ve stream'i kapat.
    func terminate()
}

public protocol StreamingProcessSpawning: Sendable {
    func spawn(executable: String, arguments: [String],
               currentDirectory: String?, environment: [String: String]) -> any StreamingProcessHandle
}
