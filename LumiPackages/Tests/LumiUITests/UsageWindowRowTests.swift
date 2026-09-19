import LumiKit
import XCTest

@testable import LumiUI

/// Kullanım barındaki tempo çizgisi (karar 74): dolgu "ne kadar harcandı"yı,
/// çizgi "pencerenin ne kadarı geçti"yi gösterir.
@MainActor
final class UsageWindowRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(percent: Int?, resetsIn: TimeInterval?, duration: TimeInterval?) -> UsageWindowRow {
        UsageWindowRow(
            title: "5-hour session",
            window: UsageWindow(
                percentUsed: percent,
                resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                resetsRaw: "raw",
                timezone: nil,
                duration: duration
            ),
            now: now
        )
    }

    func testPaceFractionFollowsElapsedWindow() {
        let row = row(percent: 12, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60)

        XCTAssertEqual(row.paceFraction ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(row.fillFraction, 0.12, accuracy: 0.0001)
    }

    func testNoMarkerWithoutReportedWindowDuration() {
        // Claude penceresi süre taşımaz → çizgi yok, bar eskisi gibi çizilir.
        XCTAssertNil(row(percent: 12, resetsIn: 3 * 60 * 60, duration: nil).paceFraction)
    }

    func testMarkerStaysInsideTheBarAtBothEnds() {
        let width: CGFloat = 200

        XCTAssertEqual(UsageWindowRow.markerOffset(for: 0, width: width), 0)
        XCTAssertEqual(UsageWindowRow.markerOffset(for: 1, width: width), width - Theme.scaled(2))
        XCTAssertEqual(
            UsageWindowRow.markerOffset(for: 0.5, width: width),
            width / 2 - Theme.scaled(2) / 2
        )
    }

    /// Satırın rengi mutlak yüzdeden değil, çizgiye olan mesafeden gelir
    /// (karar 85) — dolgu ve yüzde metni aynı rengi kullanır.
    func testFillColorFollowsTheDistanceToTheMarker() {
        // 30 puan geride (tolerans 5 + coolSpan 25) → soğuk uç.
        let behind = row(percent: 10, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60)
        XCTAssertEqual(behind.percentColor, Theme.ice)

        let onPace = row(percent: 40, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60)
        XCTAssertEqual(onPace.percentColor, Theme.success)

        let ahead = row(percent: 90, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60)
        XCTAssertEqual(ahead.percentColor, Theme.error)
    }

    func testRowWithoutDataStaysMuted() {
        XCTAssertEqual(
            row(percent: nil, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60).percentColor,
            Theme.textMuted
        )
    }

    func testHelpTextNamesTheGapBetweenUsageAndClock() {
        // %12 harcanmış, pencerenin %40'ı geçmiş → 28 puan geride.
        XCTAssertEqual(
            row(percent: 12, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60).paceHelp,
            "Window 40% elapsed · 28 pt under pace"
        )
        // %70 harcanmış, %40'ı geçmiş → 30 puan önde (limit erken biter).
        XCTAssertEqual(
            row(percent: 70, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60).paceHelp,
            "Window 40% elapsed · 30 pt over pace"
        )
        XCTAssertEqual(
            row(percent: 40, resetsIn: 3 * 60 * 60, duration: 5 * 60 * 60).paceHelp,
            "Window 40% elapsed · on pace"
        )
        XCTAssertNil(row(percent: 12, resetsIn: nil, duration: 5 * 60 * 60).paceHelp)
    }
}
