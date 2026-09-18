import LumiKit
import XCTest

@testable import LumiUI

/// Karar 55: top bar üç parçadır ve yan parçalar panellerle hizalanır.
/// Hesap saftır — view render etmeden doğrulanır.
final class TopBarRegionWidthTests: XCTestCase {
    func testLeadingRegionEndsAtTheLeftPanelEdge() {
        let width = TopBarMetrics.leadingRegionWidth(leftPanelWidth: 280)
        XCTAssertEqual(width, 280 - TopBarMetrics.contentLeading, "traffic light payı bölgeden düşer")
    }

    func testTrailingRegionEndsAtTheRightPanelEdge() {
        let width = TopBarMetrics.trailingRegionWidth(rightPanelWidth: 340)
        XCTAssertEqual(width, 340 - TopBarMetrics.trailingPadding, "bar'ın sağ payı bölgeden düşer")
    }

    func testHiddenSlotLeavesTheRegionAtItsNaturalWidth() {
        XCTAssertNil(TopBarMetrics.leadingRegionWidth(leftPanelWidth: nil))
        XCTAssertNil(TopBarMetrics.trailingRegionWidth(rightPanelWidth: nil))
    }

    /// Kullanıcı paneli bar dolgusundan dar yaparsa bölge negatife düşmez.
    func testNarrowPanelsClampToZero() {
        XCTAssertEqual(TopBarMetrics.leadingRegionWidth(leftPanelWidth: 20), 0)
        XCTAssertEqual(TopBarMetrics.trailingRegionWidth(rightPanelWidth: 4), 0)
    }

    /// Panel genişliği kalıcı yerleşimden gelir; bar ikinci bir literal tutmaz.
    func testRegionsTrackTheLayoutDefaults() {
        XCTAssertEqual(
            TopBarMetrics.leadingRegionWidth(leftPanelWidth: CGFloat(PanelLayout.defaultWidth(for: .left))),
            CGFloat(PanelLayout.defaultWidth(for: .left)) - TopBarMetrics.contentLeading
        )
        XCTAssertEqual(
            TopBarMetrics.trailingRegionWidth(rightPanelWidth: CGFloat(PanelLayout.defaultWidth(for: .right))),
            CGFloat(PanelLayout.defaultWidth(for: .right)) - TopBarMetrics.trailingPadding
        )
    }
}
