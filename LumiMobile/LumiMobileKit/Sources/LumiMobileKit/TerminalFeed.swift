import Foundation

/// Ham terminal chunk'larını bir SwiftTerm view'ına uygulayan soyut alıcı.
/// App target'taki adapter gerçek `TerminalView`'ı sarar; testte fake kullanılır.
/// `@MainActor`: SwiftTerm view'ı yalnız ana aktörde beslenebilir.
@MainActor
public protocol TerminalFeeder: AnyObject {
    func resize(cols: Int, rows: Int)
    func reset()
    func feed(bytes: [UInt8])
}

/// View hazır olana dek gelen chunk'ları tamponlar; view bağlanınca (attach)
/// tamponu SIRAYLA boşaltır ve sonraki chunk'ları anında uygular.
///
/// Kök neden (bug #3 — "terminal hep boş"): eski tasarım SwiftTerm view'ını
/// `@State` üzerinden geri kaydediyordu; view-update içinde yapılan bu `@State`
/// yazımı SwiftUI tarafından düşürülüyor/erteleniyordu, dolayısıyla view referansı
/// hiç dolmuyor ve tüm chunk'lar yalnız "bir sonraki chunk gelince boşalan" yerel
/// tamponda kalıyordu → terminal kalıcı olarak boş. Bu sınıf view referansını
/// referans-tip olarak (SwiftUI update döngüsü dışında) tutar ve tamponu attach
/// anında boşaltır; böylece boşta (yeni çıktı üretmeyen) oturumda da scrollback
/// (seq=0) görünür.
@MainActor
public final class TerminalFeedBuffer {
    private var feeder: TerminalFeeder?
    private var pending: [TerminalChunk] = []

    public init() {}

    /// Gerçek view hazır olduğunda çağrılır; birikmiş chunk'ları sırayla uygular.
    public func attach(_ feeder: TerminalFeeder) {
        self.feeder = feeder
        let buffered = pending
        pending.removeAll()
        for chunk in buffered { apply(chunk) }
    }

    /// View kaybolduğunda (onDisappear) çağrılır; sonraki chunk'lar yeniden tamponlanır.
    public func detach() {
        feeder = nil
    }

    /// Chunk'ı uygular; view yoksa tamponlar.
    public func feed(_ chunk: TerminalChunk) {
        guard feeder != nil else {
            pending.append(chunk)
            return
        }
        apply(chunk)
    }

    /// Test görünürlüğü: bekleyen (henüz uygulanmamış) chunk sayısı.
    public var pendingCount: Int { pending.count }

    private func apply(_ chunk: TerminalChunk) {
        guard let feeder else { return }
        if let cols = chunk.cols, let rows = chunk.rows {
            feeder.resize(cols: cols, rows: rows)
        }
        // seq==0: scrollback / reconnect tek-atışı → emülatörü sıfırla.
        if chunk.seq == 0 {
            feeder.reset()
        }
        feeder.feed(bytes: [UInt8](chunk.bytes))
    }
}
