import Foundation
import LumiKit

/// `UsageServicing` dekoratörü (karar 55): sarmaladığı servis verilen sürede
/// dönmezse istek İPTAL EDİLİR ve `LumiError.usageUnavailable` fırlatılır.
///
/// **Neden gerekli:** `CodexUsageService` içindeki probe'un kendi 30 sn'lik
/// deadline'ı yalnız RPC yanıtını bekler; süreç başlatma, `which` çözümü ve
/// sonlandırma o bütçenin dışındadır. Bu adımlardan biri asılınca `UsageStore`
/// `isLoading`'de kalıyor ve gösterge saatlerce dönüyordu. Üst sınır burada,
/// tek yerde ve kaynaktan bağımsız olarak zorlanır.
///
/// **Neden `withThrowingTaskGroup` değil:** grup, kapsamdan çıkarken TÜM
/// çocuklarını bekler; iptale yanıt vermeyen bir çocuk zaman aşımını da
/// yutardı. Burada kaybeden taraf arkada bırakılır (iptal edilir ama
/// beklenmez), böylece çağıran her hâlükârda `timeout` sonunda serbest kalır.
public struct TimeoutUsageService: UsageServicing {
    /// Kullanım göstergesinin üst sınırı — kullanıcı kararı: 30 sn'de yanıt
    /// yoksa istek kesilir.
    public static let defaultTimeout: Duration = .seconds(30)

    public nonisolated var provider: AgentProvider { wrapped.provider }

    private let wrapped: any UsageServicing
    private let timeout: Duration

    public init(wrapping wrapped: any UsageServicing, timeout: Duration = TimeoutUsageService.defaultTimeout) {
        self.wrapped = wrapped
        self.timeout = timeout
    }

    public func fetch() async throws -> UsageSnapshot {
        let race = FirstSettled<UsageSnapshot>()
        let wrapped = wrapped
        let work = Task {
            do {
                await race.settle(.success(try await wrapped.fetch()))
            } catch {
                await race.settle(.failure(error))
            }
        }
        let timeoutError = LumiError.usageUnavailable(detail: Self.timeoutDetail(timeout))
        let timer = Task {
            try await Task.sleep(for: timeout)
            await race.settle(.failure(timeoutError))
            // Kaynak iptale saygı duyuyorsa süreç/istek burada kapanır.
            work.cancel()
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            work.cancel()
            timer.cancel()
        }
    }

    private static func timeoutDetail(_ timeout: Duration) -> String {
        "timed out after \(timeout.components.seconds)s"
    }
}

/// İlk sonucu kazanan yarışın minik taşıyıcısı: sonraki `settle` çağrıları
/// yok sayılır, sonuç beklenmeden gelirse tamponlanır.
private actor FirstSettled<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var isSettled = false

    func value() async throws -> Value {
        if let pending { return try pending.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func settle(_ result: Result<Value, Error>) {
        guard !isSettled else { return }
        isSettled = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pending = result
        }
    }
}
