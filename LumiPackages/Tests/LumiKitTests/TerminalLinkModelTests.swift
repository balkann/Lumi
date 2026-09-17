import Foundation
import XCTest
@testable import LumiKit

/// Karar 57: link jesti çözümlemesi, çapa dönüşümü ve fare raporu tanıma.
final class TerminalLinkModelTests: XCTestCase {
    func testExecutableExtensionsAreRecognisedCaseInsensitively() {
        XCTAssertTrue(TerminalLinkSafety.isExecutable(path: "/tmp/setup.command"))
        XCTAssertTrue(TerminalLinkSafety.isExecutable(path: "/tmp/Install.PKG"))
        XCTAssertTrue(TerminalLinkSafety.isExecutable(path: "/Apps/Foo.app"))
        XCTAssertFalse(TerminalLinkSafety.isExecutable(path: "/tmp/report.pdf"))
        XCTAssertFalse(TerminalLinkSafety.isExecutable(path: "/tmp/no-extension"))
    }

    private func modifiers(
        command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false
    ) -> TerminalLinkGesture.Modifiers {
        .init(command: command, shift: shift, option: option, control: control)
    }

    func testPlainLeftClickOpensActions() {
        XCTAssertEqual(
            TerminalLinkGesture.resolve(isLeftButton: true, clickCount: 1, modifiers: modifiers()),
            .actions
        )
    }

    func testCommandClickIsPrimaryAndShiftCommandIsAlternate() {
        XCTAssertEqual(
            TerminalLinkGesture.resolve(isLeftButton: true, clickCount: 1, modifiers: modifiers(command: true)),
            .primary
        )
        XCTAssertEqual(
            TerminalLinkGesture.resolve(
                isLeftButton: true, clickCount: 1, modifiers: modifiers(command: true, shift: true)
            ),
            .alternate
        )
    }

    /// Terminale ait jestler link yoluna hiç girmez.
    func testTerminalOwnedGesturesResolveToNil() {
        XCTAssertNil(TerminalLinkGesture.resolve(
            isLeftButton: true, clickCount: 1, modifiers: modifiers(shift: true)
        ))
        XCTAssertNil(TerminalLinkGesture.resolve(
            isLeftButton: true, clickCount: 1, modifiers: modifiers(control: true)
        ))
        XCTAssertNil(TerminalLinkGesture.resolve(
            isLeftButton: true, clickCount: 1, modifiers: modifiers(command: true, option: true)
        ))
        XCTAssertNil(TerminalLinkGesture.resolve(isLeftButton: true, clickCount: 2, modifiers: modifiers()))
        XCTAssertNil(TerminalLinkGesture.resolve(isLeftButton: false, clickCount: 1, modifiers: modifiers()))
    }

    /// AppKit sol-alt orijinli pencere noktası kabuğun sol-üst uzayına döner.
    func testShellPointFlipsVerticalAxis() {
        let point = TerminalLinkAnchor.shellPoint(
            windowPoint: CGPoint(x: 120, y: 80), contentHeight: 600
        )
        XCTAssertEqual(point, CGPoint(x: 120, y: 520))
    }

    /// Dört kodlama da tanınmak zorunda: tanınmayan bir rapor bekletilmez ve
    /// tık hem popover'ı açıp hem TUI'ye ulaşırdı (çift etki).
    func testRecognizesEveryMouseReportEncoding() {
        // SGR (1006)
        XCTAssertTrue(TerminalMouseReport.isReport(Data("\u{1B}[<0;42;13M".utf8)))
        XCTAssertTrue(TerminalMouseReport.isReport(Data("\u{1B}[<0;42;13m".utf8)))
        // X10
        XCTAssertTrue(TerminalMouseReport.isReport(Data([0x1B, 0x5B, 0x4D, 0x20, 0x21, 0x22])))
        // UTF-8 (1005) — koordinatlar çok baytlı
        XCTAssertTrue(TerminalMouseReport.isReport(
            Data([0x1B, 0x5B, 0x4D, 0x20, 0xC3, 0xA1, 0xC3, 0xA2])
        ))
        // urxvt (1015)
        XCTAssertTrue(TerminalMouseReport.isReport(Data("\u{1B}[32;10;5M".utf8)))
    }

    /// Klavye girdisi ve diğer ESC dizileri asla bekletilmez.
    func testRejectsNonMouseReportPayloads() {
        XCTAssertFalse(TerminalMouseReport.isReport(Data("ls -la".utf8)))
        XCTAssertFalse(TerminalMouseReport.isReport(Data("\u{1B}[A".utf8)))
        XCTAssertFalse(TerminalMouseReport.isReport(Data("\u{1B}[<0;42M".utf8)))
        XCTAssertFalse(TerminalMouseReport.isReport(Data("\u{1B}[32;10;5X".utf8)))
        XCTAssertFalse(TerminalMouseReport.isReport(Data("\u{1B}[32;10;5m".utf8)), "urxvt yalnız M ile biter")
        XCTAssertFalse(TerminalMouseReport.isReport(Data("\u{1B}[<0;42;13X".utf8)))
        XCTAssertFalse(TerminalMouseReport.isReport(Data([0x1B, 0x5B, 0x4D, 0x20])))
    }
}
