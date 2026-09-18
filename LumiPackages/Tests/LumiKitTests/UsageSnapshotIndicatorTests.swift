import XCTest

@testable import LumiKit

/// `UsageSnapshot.indicatorLimit` — topbar göstergesinin kaynağı.
final class UsageSnapshotIndicatorTests: XCTestCase {
    private func limit(_ kind: UsageLimit.Kind, _ percent: Int) -> UsageLimit {
        UsageLimit(
            kind: kind,
            rawLabel: "raw",
            window: UsageWindow(percentUsed: percent, resetsAt: nil, resetsRaw: "", timezone: nil)
        )
    }

    private func snapshot(_ limits: [UsageLimit]) -> UsageSnapshot {
        UsageSnapshot(limits: limits, mode: .subscription, fetchedAt: Date())
    }

    /// Claude paritesi: oturum penceresi varsa sıradan bağımsız o seçilir.
    func testPrefersSessionRegardlessOfOrder() {
        let result = snapshot([limit(.weeklyAll, 40), limit(.session, 12)]).indicatorLimit

        XCTAssertEqual(result?.kind, .session)
        XCTAssertEqual(result?.window.percentUsed, 12)
    }

    /// Codex `prolite`: oturum yok → ilk pencereye düşülür.
    func testFallsBackToFirstLimitWhenNoSession() {
        let result = snapshot([limit(.weeklyAll, 63), limit(.weeklyModel("Opus"), 5)]).indicatorLimit

        XCTAssertEqual(result?.kind, .weeklyAll)
        XCTAssertEqual(result?.window.percentUsed, 63)
    }

    func testIsNilWhenNoLimitReported() {
        XCTAssertNil(snapshot([]).indicatorLimit)
    }
}
