import CoreGraphics
import XCTest
@testable import LumiUI

/// Karar 57: popover tık noktasına oturur ama her zaman kabın içinde kalır.
final class TerminalLinkPopoverPlacementTests: XCTestCase {
    private let container = CGSize(width: 1200, height: 800)
    private let popover = CGSize(width: 288, height: 120)

    private func origin(_ anchor: CGPoint) -> CGPoint {
        TerminalLinkPopoverPlacement.origin(
            anchor: anchor, popoverSize: popover, container: container
        )
    }

    /// Varsayılan yer tıkın ÜSTÜ (Orca paritesi): terminalde yeni çıktı
    /// aşağıdan geldiği için alttaki bağlam kapatılmaz.
    func testDefaultPlacementIsAboveTheClick() {
        let point = origin(CGPoint(x: 300, y: 400))
        XCTAssertEqual(point.x, 300)
        XCTAssertEqual(point.y, 400 - TerminalLinkPopoverPlacement.gap - popover.height)
    }

    /// Üste sığmıyorsa alta iner.
    func testFlipsBelowWhenItWouldOverflowTheTop() {
        let point = origin(CGPoint(x: 300, y: 40))
        XCTAssertEqual(point.y, 40 + TerminalLinkPopoverPlacement.gap)
    }

    func testClampsToTheRightEdge() {
        let point = origin(CGPoint(x: 1190, y: 100))
        XCTAssertEqual(point.x, container.width - popover.width - TerminalLinkPopoverPlacement.gap)
    }

    func testClampsToTheTopAndLeftEdges() {
        let point = origin(CGPoint(x: 0, y: 0))
        XCTAssertEqual(point.x, TerminalLinkPopoverPlacement.gap)
        XCTAssertGreaterThanOrEqual(point.y, TerminalLinkPopoverPlacement.gap)
    }

    /// Kap popover'dan küçükse bile sonuç negatif olmaz.
    func testTinyContainerStillProducesAVisibleOrigin() {
        let point = TerminalLinkPopoverPlacement.origin(
            anchor: CGPoint(x: 10, y: 10),
            popoverSize: popover,
            container: CGSize(width: 100, height: 60)
        )
        XCTAssertEqual(point.x, TerminalLinkPopoverPlacement.gap)
        XCTAssertEqual(point.y, TerminalLinkPopoverPlacement.gap)
    }
}
