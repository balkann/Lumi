import Foundation
import LumiKit
import LumiTestSupport
import XCTest

@testable import LumiServices

/// Karar 55: kullanım isteğinin üst sınırı. Codex probe'u (süreç spawn'ı + RPC)
/// asılınca gösterge `isLoading`'de kalıyordu; dekoratör çağıranı her hâlükârda
/// serbest bırakır.
final class TimeoutUsageServiceTests: XCTestCase {
    /// Testlerin gerçek zamanda beklediği süre — 30 sn'lik üretim değeri değil.
    private static let testTimeout: Duration = .milliseconds(80)

    private func snapshot() -> UsageSnapshot {
        UsageSnapshot(
            limits: [
                UsageLimit(
                    kind: .session,
                    rawLabel: "Current session",
                    window: UsageWindow(percentUsed: 12, resetsAt: nil, resetsRaw: "", timezone: nil)
                ),
            ],
            mode: .subscription,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testFastSourcePassesItsSnapshotThrough() async throws {
        let inner = FakeUsageService(provider: .codex, outcome: .success(snapshot()))
        let service = TimeoutUsageService(wrapping: inner, timeout: Self.testTimeout)

        let result = try await service.fetch()

        XCTAssertEqual(result.fiveHour?.percentUsed, 12)
        XCTAssertEqual(service.provider, .codex, "sağlayıcı kimliği dekoratörden geçer")
    }

    func testSourceErrorIsNotMaskedByTheTimeout() async {
        let inner = FakeUsageService(outcome: .failure(.cliNotFound(binary: "codex")))
        let service = TimeoutUsageService(wrapping: inner, timeout: Self.testTimeout)

        do {
            _ = try await service.fetch()
            XCTFail("kaynak hatası yukarı çıkmalı")
        } catch let error as LumiError {
            guard case .cliNotFound(let binary) = error else {
                return XCTFail("beklenmeyen hata: \(error)")
            }
            XCTAssertEqual(binary, "codex")
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }

    func testHangingSourceFailsWithUsageUnavailable() async {
        let service = TimeoutUsageService(
            wrapping: HangingUsageService(ignoresCancellation: false),
            timeout: Self.testTimeout
        )

        do {
            _ = try await service.fetch()
            XCTFail("asılı kaynak zaman aşımına uğramalı")
        } catch let error as LumiError {
            guard case .usageUnavailable(let detail) = error else {
                return XCTFail("beklenmeyen hata: \(error)")
            }
            XCTAssertTrue(detail.contains("timed out"), detail)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }

    /// Asıl güvence: iptale saygı duymayan bir kaynak bile çağıranı bekletmez
    /// (bir task group kullanılsaydı kapsam çıkışında o çocuğu beklerdi).
    func testCallerIsReleasedEvenWhenTheSourceIgnoresCancellation() async {
        let service = TimeoutUsageService(
            wrapping: HangingUsageService(ignoresCancellation: true),
            timeout: Self.testTimeout
        )

        let started = Date()
        _ = try? await service.fetch()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.0, "kaybeden istek arkada bırakılır, beklenmez")
    }
}

/// Hiç dönmeyen kaynak; `ignoresCancellation` ile iptali yutan sürüm.
private struct HangingUsageService: UsageServicing {
    let ignoresCancellation: Bool
    var provider: AgentProvider { .codex }

    func fetch() async throws -> UsageSnapshot {
        if ignoresCancellation {
            // İptali yutar: `Task.sleep`'in `CancellationError`'ı bilinçli
            // olarak atılır (asılı bir süreç beklemesinin benzeri).
            try? await Task.sleep(for: .seconds(5))
            try? await Task.sleep(for: .seconds(5))
        } else {
            try await Task.sleep(for: .seconds(5))
        }
        throw LumiError.usageUnavailable(detail: "unreachable")
    }
}
