import Foundation
import LumiKit
import LumiTestSupport
import XCTest

@testable import LumiState

/// Bakiye store'unun sözleşmesi (karar 75): kapalıyken istek yok, hata son
/// bakiyeyi korur, manuel yenilemede anti-spam aralığı.
@MainActor
final class DeepSeekBalanceStoreTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(
        _ service: FakeDeepSeekBalanceService
    ) -> DeepSeekBalanceStore {
        DeepSeekBalanceStore(service: service, now: { [weak self] in self?.clock ?? Date() })
    }

    func testDisabledStoreNeverCallsTheService() async {
        let service = FakeDeepSeekBalanceService()
        let store = makeStore(service)

        await store.loadInitialIfNeeded()
        await store.refresh()

        let count = await service.fetchCount
        XCTAssertEqual(count, 0, "kapalı gösterge hiç istek atmaz")
        XCTAssertNil(store.balance)
    }

    func testInitialLoadRunsOnceWhileEnabled() async {
        let service = FakeDeepSeekBalanceService()
        let store = makeStore(service)
        store.setEnabled(true)

        await store.loadInitialIfNeeded()
        await store.loadInitialIfNeeded()

        let count = await service.fetchCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.balance?.primary?.total, Decimal(string: "1.69"))
        XCTAssertEqual(store.statusKind, .updated(fetchedAt: store.balance!.fetchedAt))
    }

    func testRefreshIsThrottledUntilMinimumInterval() async {
        let service = FakeDeepSeekBalanceService()
        let store = makeStore(service)
        store.setEnabled(true)
        await store.loadInitialIfNeeded()

        await store.refresh()
        var count = await service.fetchCount
        XCTAssertEqual(count, 1, "aralık dolmadan yenilenmez")

        clock.addTimeInterval(DeepSeekBalanceStore.minRefreshInterval)
        await store.refresh()
        count = await service.fetchCount
        XCTAssertEqual(count, 2)
    }

    func testFailureKeepsTheLastBalanceAndShowsTheError() async {
        let service = FakeDeepSeekBalanceService()
        let store = makeStore(service)
        store.setEnabled(true)
        await store.loadInitialIfNeeded()
        let fetchedAt = store.balance!.fetchedAt

        await service.setOutcome(.failure(.deepSeekBalanceUnavailable(detail: "HTTP 401 — invalid API key")))
        clock.addTimeInterval(DeepSeekBalanceStore.minRefreshInterval)
        await store.refresh()

        XCTAssertEqual(store.balance?.fetchedAt, fetchedAt, "bakiye korunur (karar 5)")
        XCTAssertEqual(
            store.statusKind,
            .staleWithError(
                fetchedAt: fetchedAt,
                message: "Could not read DeepSeek balance: HTTP 401 — invalid API key"
            )
        )
    }

    func testKeyChangeRefreshesWithoutWaitingForTheInterval() async {
        let service = FakeDeepSeekBalanceService()
        let store = makeStore(service)
        store.setEnabled(true)
        await store.loadInitialIfNeeded()

        await store.refreshAfterKeyChange()

        let count = await service.fetchCount
        XCTAssertEqual(count, 2, "kaynak değişti — beklemek yanlış bilgiyi korurdu")
    }

    func testClearDropsStaleBalance() async {
        let service = FakeDeepSeekBalanceService()
        let store = makeStore(service)
        store.setEnabled(true)
        await store.loadInitialIfNeeded()

        store.clear()

        XCTAssertNil(store.balance)
        XCTAssertEqual(store.statusKind, .idle)
    }
}
