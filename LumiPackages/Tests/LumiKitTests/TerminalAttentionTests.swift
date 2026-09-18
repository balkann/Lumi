import XCTest
@testable import LumiKit

/// Karar 77: seçili olmayan terminal turn'ünü kapatınca ya da karar bekleyince
/// başlığı vurgulanır. Kural view'sız yaşar, iki yüzey de buradan beslenir.
final class TerminalAttentionTests: XCTestCase {
    private func isNeeded(
        _ status: TerminalStatus,
        awaiting: Bool = false,
        selected: Bool = false
    ) -> Bool {
        TerminalAttention.isNeeded(status: status, isAwaitingDecision: awaiting, isSelected: selected)
    }

    func testUnseenWaitIsHighlighted() {
        XCTAssertTrue(isNeeded(.waitingUnseen))
    }

    /// Odaktayken bekleyen terminalde vurgu yok — kullanıcı zaten bakıyor.
    func testFocusedWaitIsNotHighlighted() {
        XCTAssertFalse(isNeeded(.waitingFocused, selected: true))
    }

    /// `waitingSeen`: kullanıcı beklemeyi odaktayken GÖRDÜ, sonra başka yere
    /// geçti. Tekrar sarıya döndürmek "yeni bir şey oldu" yalanı olurdu.
    func testSeenWaitIsNotHighlightedAgain() {
        XCTAssertFalse(isNeeded(.waitingSeen))
    }

    func testWorkingAndIdleAreNotHighlighted() {
        XCTAssertFalse(isNeeded(.working))
        XCTAssertFalse(isNeeded(.idle))
        XCTAssertFalse(isNeeded(.error))
    }

    /// Karar bekleme durumu `working` olarak kaldığı için ayrı sinyaldir.
    func testAwaitingDecisionHighlightsUnselectedTerminal() {
        XCTAssertTrue(isNeeded(.working, awaiting: true))
    }

    func testAwaitingDecisionOnSelectedTerminalIsNotHighlighted() {
        XCTAssertFalse(isNeeded(.working, awaiting: true, selected: true))
    }

    /// Seçili terminal `waitingUnseen`'de kalabilir (yüzey gizliyken odak
    /// servise `nil` gider ama `activeTerminalID` korunur) — vurgu yine çıkar,
    /// çünkü terminal gerçekten görülmedi.
    func testUnseenWaitStillHighlightsTheSelectedButHiddenTerminal() {
        XCTAssertTrue(isNeeded(.waitingUnseen, selected: true))
    }
}
