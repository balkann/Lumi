import XCTest

@testable import LumiKit

/// Pencerenin ne kadarının geçtiği (karar 74) — kullanım yüzdesiyle
/// kıyaslanacak "tempo" değeri.
final class UsageWindowPaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        resetsIn seconds: TimeInterval?,
        duration: TimeInterval?
    ) -> UsageWindow {
        UsageWindow(
            percentUsed: 30,
            resetsAt: seconds.map { now.addingTimeInterval($0) },
            resetsRaw: "raw",
            timezone: nil,
            duration: duration
        )
    }

    func testElapsedFractionIsWindowMinusRemaining() {
        // 5 saatlik pencerenin 3 saati kaldıysa 2 saati geçmiştir → %40.
        let window = window(resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60)

        XCTAssertEqual(window.elapsedFraction(now: now) ?? 0, 0.4, accuracy: 0.0001)
    }

    func testMissingDurationYieldsNoFraction() {
        // Claude OAuth yanıtı pencere uzunluğu döndürmez → çizgi çizilmez.
        XCTAssertNil(window(resetsIn: 3 * 60 * 60, duration: nil).elapsedFraction(now: now))
    }

    func testMissingResetDateYieldsNoFraction() {
        XCTAssertNil(window(resetsIn: nil, duration: 5 * 60 * 60).elapsedFraction(now: now))
    }

    func testNonPositiveDurationYieldsNoFraction() {
        XCTAssertNil(window(resetsIn: 3 * 60 * 60, duration: 0).elapsedFraction(now: now))
    }

    func testClampsToOneWhenResetIsOverdue() {
        // Reset geçmişte kaldıysa (yenilenmemiş snapshot) pencere dolmuştur.
        XCTAssertEqual(window(resetsIn: -60, duration: 5 * 60 * 60).elapsedFraction(now: now), 1)
    }

    func testClampsToZeroWhenResetIsFartherThanWindow() {
        // Saat kayması: reset pencere boyundan uzaksa henüz hiç geçmemiştir.
        XCTAssertEqual(window(resetsIn: 6 * 60 * 60, duration: 5 * 60 * 60).elapsedFraction(now: now), 0)
    }
}
