import CoreGraphics
import XCTest
@testable import LumiUI

/// Kenar hover sensörünün **saf** kararı (karar 59). Bu kural, karar 44'ün üç
/// hover hatasını da kapatır: terminal üstünde tetiklenmeme, popover açılınca
/// yanlış kapanma, kaçan çıkışta kapanmama.
final class PointerPresenceRuleTests: XCTestCase {
    private let region = CGRect(x: 0, y: 0, width: 100, height: 400)

    func testPointerInsideRegionIsInside() {
        XCTAssertTrue(PointerPresenceRule.isInside(
            pointer: CGPoint(x: 50, y: 200),
            region: region,
            isAppActive: true,
            isPointerInAttachedWindow: false
        ))
    }

    func testPointerOutsideRegionIsOutside() {
        XCTAssertFalse(PointerPresenceRule.isInside(
            pointer: CGPoint(x: 400, y: 200),
            region: region,
            isAppActive: true,
            isPointerInAttachedWindow: false
        ))
    }

    /// Panelin kendi popover'ı / açılır listesi bölgenin dışına taşsa bile
    /// panel açık kalmalıdır.
    func testPointerInAttachedWindowStaysInsideEvenOutsideRegion() {
        XCTAssertTrue(PointerPresenceRule.isInside(
            pointer: CGPoint(x: 400, y: 200),
            region: region,
            isAppActive: true,
            isPointerInAttachedWindow: true
        ))
    }

    func testInactiveAppIsAlwaysOutside() {
        XCTAssertFalse(PointerPresenceRule.isInside(
            pointer: CGPoint(x: 50, y: 200),
            region: region,
            isAppActive: false,
            isPointerInAttachedWindow: true
        ))
    }

    /// Pencereye girmemiş / gizli view: ölçülebilir bölge yok → hover da yok.
    func testMissingRegionIsOutside() {
        XCTAssertFalse(PointerPresenceRule.isInside(
            pointer: CGPoint(x: 50, y: 200),
            region: nil,
            isAppActive: true,
            isPointerInAttachedWindow: false
        ))
    }
}
