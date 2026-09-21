import LumiKit
import SwiftUI
import XCTest
@testable import LumiUI

/// Tempo rampasının tema eşlemesi (karar 85): eşikler ve aritmetik LumiKit'te
/// (`UsagePaceTests`), burada yalnız rampanın durakları kilitlenir.
@MainActor
final class UsagePaceColorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(percent: Int?, resetsIn: TimeInterval?, duration: TimeInterval?) -> UsageWindow {
        UsageWindow(
            percentUsed: percent,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            resetsRaw: "raw",
            timezone: nil,
            duration: duration
        )
    }

    /// 5 saatlik pencerenin %40'ı geçmiş (3 saat kaldı) — tempo çizgisi 0.4'te.
    private func fortyPercentElapsed(percent: Int?) -> UsageWindow {
        window(percent: percent, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60)
    }

    private func pace(_ percent: Int, elapsed: Double) -> UsagePace {
        UsagePace(percentUsed: percent, elapsedFraction: elapsed)!
    }

    func testRampStopsMapToPaletteTokens() {
        // Tam geride → buz mavisi, tempoda → yeşil, orta sıcak → sarı, uç → kırmızı.
        XCTAssertEqual(pace(10, elapsed: 0.40).color, Theme.ice)
        XCTAssertEqual(pace(40, elapsed: 0.40).color, Theme.success)
        XCTAssertEqual(pace(65, elapsed: 0.40).color, Theme.warning)
        XCTAssertEqual(pace(85, elapsed: 0.40).color, Theme.error)
    }

    func testToleranceBandKeepsTheNormalColorNearTheMarker() {
        XCTAssertEqual(pace(35, elapsed: 0.40).color, Theme.success)
        XCTAssertEqual(pace(45, elapsed: 0.40).color, Theme.success)
    }

    func testRampIsContinuousBetweenTheStops() {
        // Duraklar arası ara tondur: uçların hiçbirine eşit değildir.
        let midCool = pace(22, elapsed: 0.40).color
        XCTAssertNotEqual(midCool, Theme.ice)
        XCTAssertNotEqual(midCool, Theme.success)

        let midWarm = pace(55, elapsed: 0.40).color
        XCTAssertNotEqual(midWarm, Theme.success)
        XCTAssertNotEqual(midWarm, Theme.warning)
    }

    func testBlendEndpointsAreTheTokensThemselves() {
        XCTAssertEqual(Theme.blend(Theme.Hex.success, Theme.Hex.ice, 0), Theme.success)
        XCTAssertEqual(Theme.blend(Theme.Hex.success, Theme.Hex.ice, 1), Theme.ice)
        // Kırpma: rampa dışına taşan değer uçta durur.
        XCTAssertEqual(Theme.blend(Theme.Hex.warning, Theme.Hex.error, 4), Theme.error)
    }

    func testWindowWithoutDurationFallsBackToTheAbsoluteBand() {
        // Claude'un tanınmayan pencere türü: tempo yok → eski 50/80 bandı.
        let noDuration = window(percent: 85, resetsIn: 3 * 60 * 60, duration: nil)
        XCTAssertEqual(UsageTint.color(for: noDuration, now: now), Theme.error)

        let comfortable = window(percent: 10, resetsIn: 3 * 60 * 60, duration: nil)
        XCTAssertEqual(UsageTint.color(for: comfortable, now: now), Theme.success)
    }

    func testTintIsNilWithoutAnyPercent() {
        XCTAssertNil(UsageTint.color(for: fortyPercentElapsed(percent: nil), now: now))
    }

    func testTintPrefersPaceOverTheAbsoluteBand() {
        // %60 mutlak bantta SARI olurdu; pencerenin %40'ı geçmişken 20 puan
        // öndedir, yani rampanın sıcak yarısında ama henüz sarıda değil.
        let tint = UsageTint.color(for: fortyPercentElapsed(percent: 60), now: now)
        XCTAssertNotEqual(tint, UsageLevel(percent: 60).color)
        XCTAssertEqual(tint, pace(60, elapsed: 0.40).color)
    }
}
