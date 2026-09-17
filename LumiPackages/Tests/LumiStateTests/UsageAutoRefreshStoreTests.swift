import XCTest
@testable import LumiKit
import LumiTestSupport
@testable import LumiState

/// UsageAutoRefreshStore davranışı (karar 20): idle-gate'li tek adım — kullanıcı
/// aktifse tazeler, pasifse atlar. Aralık clamping model katmanında.
@MainActor
final class UsageAutoRefreshStoreTests: XCTestCase {
    private func snapshot(percent: Int) -> UsageSnapshot {
        UsageSnapshot(
            limits: [
                UsageLimit(
                    kind: .session,
                    rawLabel: "Current session",
                    window: UsageWindow(percentUsed: percent, resetsAt: nil, resetsRaw: "", timezone: nil)
                )
            ],
            mode: .subscription,
            fetchedAt: Date()
        )
    }

    func testTickRefreshesWhenUserActive() async {
        // Arrange: idle (10sn) << aralık (5dk = 300sn) → aktif kabul edilir.
        let service = FakeUsageService(outcome: .success(snapshot(percent: 11)))
        let usage = UsageStore(service: service)
        let activity = FakeActivityMonitor(idleSeconds: 10)
        let store = UsageAutoRefreshStore(stores: [usage], activity: activity)
        store.update(UsageAutoRefresh(enabled: true, intervalMinutes: 5))

        // Act
        let didRefresh = await store.performTickIfActive()

        // Assert
        XCTAssertTrue(didRefresh)
        let count = await service.fetchCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(usage.fiveHourPercent, 11)
        store.stop()
    }

    func testTickSkipsWhenUserIdleBeyondInterval() async {
        // Arrange: idle (10000sn) >= aralık (300sn) → pasif → tazelenmez.
        let service = FakeUsageService(outcome: .success(snapshot(percent: 11)))
        let usage = UsageStore(service: service)
        let activity = FakeActivityMonitor(idleSeconds: 10_000)
        let store = UsageAutoRefreshStore(stores: [usage], activity: activity)
        store.update(UsageAutoRefresh(enabled: true, intervalMinutes: 5))

        // Act
        let didRefresh = await store.performTickIfActive()

        // Assert
        XCTAssertFalse(didRefresh)
        let count = await service.fetchCount
        XCTAssertEqual(count, 0)
        XCTAssertNil(usage.fiveHourPercent)
        store.stop()
    }

    // MARK: - Aralık seti (karar 55: {1, 5}, default 5)

    func testAllowedIntervalsMatchTheDesignRecord() {
        XCTAssertEqual(UsageAutoRefresh.allowedIntervals, [1, 5])
        XCTAssertEqual(UsageAutoRefresh.defaults.intervalMinutes, 5)
    }

    func testEveryAllowedIntervalSurvivesValidation() {
        for minutes in UsageAutoRefresh.allowedIntervals {
            XCTAssertEqual(
                UsageAutoRefresh(enabled: true, intervalMinutes: minutes).intervalMinutes,
                minutes
            )
        }
    }

    func testIntervalClampsInvalidToDefault() {
        for invalid in [0, 2, 7, 15, 30, 31, -5] {
            XCTAssertEqual(
                UsageAutoRefresh(enabled: true, intervalMinutes: invalid).intervalMinutes,
                UsageAutoRefresh.defaults.intervalMinutes,
                "\(invalid) izinli set dışında — default'a düşmeli"
            )
        }
    }

    /// En küçük aralık `UsageStore`'un anti-spam kapısından (60 sn) kısa
    /// OLAMAZ; olsaydı döngü kapıya takılıp boşa dönerdi.
    func testSmallestIntervalIsNotShorterThanTheStoreRefreshGate() throws {
        let smallest = try XCTUnwrap(UsageAutoRefresh.allowedIntervals.min())
        XCTAssertGreaterThanOrEqual(
            TimeInterval(smallest * 60),
            UsageStore.minRefreshInterval
        )
    }

    /// Diskteki eski `intervalMinutes: 15` (karar 55 öncesi set) okumada
    /// default'a clamp'lenir.
    func testLegacyFifteenMinuteIntervalIsClampedOnRead() {
        XCTAssertEqual(
            UsageAutoRefresh(enabled: true, intervalMinutes: 15),
            UsageAutoRefresh(enabled: true, intervalMinutes: 5)
        )
    }

    /// Clamp gerçekten döngüyü de etkiler: `30` yazılsa bile idle-gate 5 dk'lık
    /// pencereyi kullanır (200 sn boşta olan kullanıcı hâlâ "aktif" sayılır).
    func testLoopUsesClampedIntervalForTheIdleGate() async {
        let service = FakeUsageService(outcome: .success(snapshot(percent: 11)))
        let usage = UsageStore(service: service)
        // 200 sn boşta: 1 dk (60 sn) penceresinde pasif, 5 dk (300 sn) penceresinde aktif.
        let activity = FakeActivityMonitor(idleSeconds: 200)
        let store = UsageAutoRefreshStore(stores: [usage], activity: activity)
        store.update(UsageAutoRefresh(enabled: true, intervalMinutes: 30))

        let didRefresh = await store.performTickIfActive()

        XCTAssertTrue(didRefresh, "aralık 5'e clamp'lendiği için kullanıcı aktif sayılır")
        store.stop()
    }

    /// 1 dk aralığı gerçek bir tazeleme üretir: idle-gate 60 sn'lik pencereyi
    /// kullanır ve döngü TTL cache'ini geçersizleyerek kaynağa gider.
    func testOneMinuteIntervalRefreshesWhenTheUserIsActive() async {
        let service = FakeUsageService(outcome: .success(snapshot(percent: 11)))
        let usage = UsageStore(service: service, cache: service)
        let store = UsageAutoRefreshStore(stores: [usage], activity: FakeActivityMonitor(idleSeconds: 10))
        store.update(UsageAutoRefresh(enabled: true, intervalMinutes: 1))

        let didRefresh = await store.performTickIfActive()

        XCTAssertTrue(didRefresh)
        let invalidations = await service.invalidateCount
        XCTAssertEqual(invalidations, 1, "döngü cache'i geçersizler — 300 sn TTL'e takılmaz")
        store.stop()
    }
}
