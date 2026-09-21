import Foundation
import LumiKit
import os

/// Tek tüketicili `AsyncStream` döngüsünün yaşam döngüsü (refactor 3.4).
///
/// İki kuralı yapısal olarak garanti eder:
///
/// 1. **Stream Task'tan ÖNCE alınır.** Çağıran `service.events()`'i senkron
///    çağırıp buraya verir; abonelik `start()` döndüğünde kuruludur, boot
///    penceresinde event kaybolmaz (plan 5.6).
/// 2. **`stop()` eşzamanlıdır.** `Task.cancel()` yalnızca *isteği* iletir:
///    tüketici `for await`'te askıdaysa iptal bir sonraki tura kadar
///    görülmez, bu pencerede gelen event ESKİ tüketici tarafından uygulanabilir
///    (start-stop-start'ta aynı event iki kez). Nesil (generation) sayacı bunu
///    kapatır: `stop()` nesli ilerletir, eski tüketici uyandığında neslini
///    doğrulayamaz ve hiçbir mutasyon uygulamadan çıkar. `stop()` MainActor'da
///    koştuğu için döndüğü anda garanti yürürlüktedir.
///
/// Teşhis izi (karar 83): döngünün başlangıcı, her çıkışı (neden + işlenen
/// olay sayısı) ve `stop()` çağrısı (çağıran yığını) unified log'a yazılır.
/// `describe` verilirse her olay uygulanmadan önce (`←`) ve sonra (`✓`) bir
/// satır düşer — döngü bir olayın ortasında sessizce ölürse son `←` satırı
/// suçluyu gösterir.
@MainActor
public final class EventConsumer {
    private static let logger = LumiLog.logger("events")

    private var task: Task<Void, Never>?
    private var generation = 0
    private let label: String
    /// Teşhis: bu tüketicinin başlangıçtan beri işlediği olay sayısı.
    public private(set) var eventsHandled = 0
    /// Teşhis: döngünün son çıkış nedeni (`nil` = hiç çıkmadı ya da başlamadı).
    public private(set) var lastExitReason: String?

    public init(label: String = "events") {
        self.label = label
    }

    public var isRunning: Bool { task != nil }

    /// Idempotent başlatma. `prologue` ilk event'ten önce koşar (ör. ilk
    /// yükleme); nesil kontrolü prologue'dan sonra da yapılır.
    ///
    /// `stream` `@autoclosure`'dır: idempotence kontrolünden SONRA, ama Task
    /// kurulmadan ÖNCE senkron değerlendirilir. Argüman olarak geçseydi ikinci
    /// `start()` çağrısı tüketmeyeceği bir abonelik daha açardı.
    public func start<Event: Sendable>(
        _ stream: @autoclosure () -> AsyncStream<Event>,
        prologue: (@MainActor () async -> Void)? = nil,
        describe: (@Sendable (Event) -> String)? = nil,
        handle: @escaping @MainActor (Event) async -> Void
    ) {
        guard task == nil else { return }
        let stream = stream()
        generation += 1
        let epoch = generation
        let label = self.label
        Self.logger.log("[\(label, privacy: .public)] consumer start (epoch \(epoch))")
        task = Task { @MainActor [weak self] in
            await prologue?()
            guard self?.generation == epoch else {
                Self.logger.log("[\(label, privacy: .public)] consumer left after prologue (epoch \(epoch))")
                return
            }
            var handled = 0
            for await event in stream {
                guard let self, self.generation == epoch else {
                    Self.logger.log("[\(label, privacy: .public)] consumer superseded (epoch \(epoch), handled \(handled))")
                    return
                }
                if let describe {
                    Self.logger.log("[\(label, privacy: .public)] ← \(describe(event), privacy: .public)")
                }
                // `await`: event işleme SERİdir — bir tur bitmeden sonraki
                // event işlenmez (repo reload'larının sırası bu garantiye bağlı).
                await handle(event)
                handled += 1
                self.eventsHandled = handled
                if let describe {
                    Self.logger.log("[\(label, privacy: .public)] ✓ \(describe(event), privacy: .public)")
                }
            }
            let reason = Task.isCancelled ? "cancelled" : "stream finished"
            self?.lastExitReason = reason
            Self.logger.log(
                "[\(label, privacy: .public)] consumer loop ended: \(reason, privacy: .public) (epoch \(epoch), handled \(handled))"
            )
        }
    }

    public func stop() {
        let callers = Thread.callStackSymbols.dropFirst().prefix(6).joined(separator: " | ")
        Self.logger.log(
            "[\(self.label, privacy: .public)] stop() running=\(self.task != nil) from: \(callers, privacy: .public)"
        )
        task?.cancel()
        task = nil
        // Nesil ilerlemesi iptalin gecikmesini telafi eder (bkz. tip yorumu).
        generation += 1
    }
}
