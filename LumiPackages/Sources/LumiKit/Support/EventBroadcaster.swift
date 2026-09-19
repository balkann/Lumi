import Foundation
import os

private let broadcasterLogger = LumiLog.logger("broadcaster")

/// Servis→store event dağıtımı için continuation registry'si (design/02 girişi).
/// Her `stream()` çağrısı bağımsız bir AsyncStream döner; `send` hepsine yield eder.
/// Tasarım gereği her domain'in tek tüketicisi (kendi store'u) vardır, ancak
/// testler ve geçici dinleyiciler için çoklu stream desteklenir.
public final class EventBroadcaster<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private let bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy
    /// Teşhis izi (karar 83): log satırlarında hangi kanal olduğu.
    private let label: String

    /// Varsayılan `.unbounded` mevcut davranışı korur (yaşam döngüsü event'leri
    /// düşük hacimli ve kayıpsız olmalı). Yüksek hacimli/drop'a toleranslı
    /// akışlar `.bufferingNewest(_:)` ile sınırlanabilir.
    public init(
        label: String = "events",
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .unbounded
    ) {
        self.label = label
        self.bufferingPolicy = bufferingPolicy
    }

    public func stream() -> AsyncStream<Event> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            let label = self.label
            continuation.onTermination = { [weak self] reason in
                // Karar 83: tüketici stream'i bırakırsa (iptal/bitiş) iz kalsın —
                // bundan sonra `send` bu aboneye ulaşamaz.
                broadcasterLogger.log(
                    "[\(label, privacy: .public)] stream terminated: \(String(describing: reason), privacy: .public)"
                )
                self?.remove(id)
            }
        }
    }

    public func send(_ event: Event) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    public func finishAll() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        let remaining = continuations.count
        lock.unlock()
        broadcasterLogger.log("[\(self.label, privacy: .public)] subscriber removed, remaining \(remaining)")
    }
}
