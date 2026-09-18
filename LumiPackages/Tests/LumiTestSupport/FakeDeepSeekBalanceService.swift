import Foundation
import LumiKit

/// `DeepSeekBalanceServicing` test ikamesi (karar 75): ağ yok, sonuç
/// scriptlenir. `FakeUsageService` ile aynı desen — `actor`, çağrı sayacı
/// "kapalı gösterge istek atmaz" testlerinin kaynağıdır.
public actor FakeDeepSeekBalanceService: DeepSeekBalanceServicing {
    public enum Outcome: Sendable {
        case success(DeepSeekBalance)
        case failure(LumiError)
    }

    private var outcome: Outcome
    public private(set) var fetchCount = 0

    public init(outcome: Outcome = .success(.fake())) {
        self.outcome = outcome
    }

    public func setOutcome(_ outcome: Outcome) {
        self.outcome = outcome
    }

    public func fetch() async throws -> DeepSeekBalance {
        fetchCount += 1
        switch outcome {
        case .success(let balance): return balance
        case .failure(let error): throw error
        }
    }
}

public extension DeepSeekBalance {
    /// Testlerin paylaştığı örnek bakiye (USD 1.69 — gerçek yanıt biçimi).
    static func fake(
        isAvailable: Bool = true,
        total: Decimal = 1.69,
        granted: Decimal = 0,
        toppedUp: Decimal = 1.69,
        currency: String = "USD",
        fetchedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> DeepSeekBalance {
        DeepSeekBalance(
            isAvailable: isAvailable,
            accounts: [
                Account(currency: currency, total: total, granted: granted, toppedUp: toppedUp)
            ],
            fetchedAt: fetchedAt
        )
    }
}
