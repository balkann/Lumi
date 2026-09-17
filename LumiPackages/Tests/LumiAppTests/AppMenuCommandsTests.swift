import Foundation
import LumiKit
import LumiState
import LumiTestSupport
import XCTest
@testable import LumiAppCore

/// Menü komutlarının store'lara BAĞLANMA davranışı (karar 55).
///
/// `MenuActionDispatcherTests` yalnız yönlendirmeyi (id → closure) kilitler;
/// burası closure'ın gerçekten ne yaptığını kilitler — repo tab'ları ile
/// terminal odağının iki ayrı eksen olduğu ve ⌘W'nin terminal yokken tab'a
/// düştüğü sözleşme.
@MainActor
final class AppMenuCommandsTests: XCTestCase {
    private var dispatcher: MenuActionDispatcher!
    private var shared: SharedStores!
    private var terminalService: FakeTerminalService!

    override func setUp() async throws {
        terminalService = FakeTerminalService()
        shared = SharedStores.make(
            config: FakeConfigService(),
            terminal: terminalService,
            viewProvider: FakeTerminalViewProvider(),
            toastAutoDismissAfter: 60
        )
        dispatcher = MenuActionDispatcher()
        AppMenuCommands.register(in: dispatcher, shared: shared, openSettings: {})
        // Terminal listesi servis stream'inden akar: lifecycle başlamadan
        // spawn edilen terminal store'a düşmez.
        await shared.terminals.start()
    }

    override func tearDown() {
        shared.terminals.stop()
    }

    // MARK: - ⌃1…⌃9 repo tab'ını değiştirir

    func testSwitchToTabActivatesTheTabAtTheGivenIndex() {
        shared.navigation.openTab("/r/alpha")
        shared.navigation.openTab("/r/beta")
        shared.navigation.openTab("/r/gamma")

        dispatcher.perform(.switchToTabAtIndex, index: 2)

        XCTAssertEqual(shared.navigation.activeRepoPath, "/r/beta")
    }

    /// Açık tab sayısından büyük indeks sessizce yutulur — ⌃9 üç tab'lıyken
    /// aktif tab'ı DEĞİŞTİRMEZ.
    func testSwitchToTabIgnoresIndexBeyondOpenTabs() {
        shared.navigation.openTab("/r/alpha")
        shared.navigation.openTab("/r/beta")

        dispatcher.perform(.switchToTabAtIndex, index: 9)

        XCTAssertEqual(shared.navigation.activeRepoPath, "/r/beta")
    }

    /// İki indeksli aile aynı eksende DEĞİL: ⌘N terminal odaklar, tab'a
    /// dokunmaz.
    func testFocusTerminalAtIndexDoesNotChangeTheActiveTab() {
        shared.navigation.openTab("/r/alpha")
        shared.navigation.openTab("/r/beta")

        dispatcher.perform(.focusTerminalAtIndex, index: 1)

        XCTAssertEqual(shared.navigation.activeRepoPath, "/r/beta")
    }

    // MARK: - ⌘W

    func testCloseTerminalClosesTheActiveTerminalWhenThereIsOne() async throws {
        shared.navigation.openTab("/r/alpha")
        shared.terminals.spawn(in: "/r/alpha", command: nil)
        await waitUntil("terminal store'a düşmedi") { self.shared.terminals.activeTerminalID != nil }
        let id = try XCTUnwrap(shared.terminals.activeTerminalID)

        dispatcher.perform(.closeTerminal)

        XCTAssertEqual(terminalService.killedIDs, [id])
        XCTAssertEqual(shared.navigation.openTabs, ["/r/alpha"], "tab kapanmamalı")
    }

    /// Electron paritesi: terminal yoksa ⌘W repo TAB'ını kapatır.
    func testCloseTerminalClosesTheActiveTabWhenNoTerminalIsOpen() {
        shared.navigation.openTab("/r/alpha")
        shared.navigation.openTab("/r/beta")

        dispatcher.perform(.closeTerminal)

        XCTAssertEqual(shared.navigation.openTabs, ["/r/alpha"])
        XCTAssertEqual(shared.navigation.activeRepoPath, "/r/alpha")
    }

    /// Hiç tab yokken ⌘W hiçbir şey yapmaz (pencere KAPANMAZ — menü
    /// interception'ın tüm amacı bu).
    func testCloseTerminalIsANoOpWithoutTerminalsOrTabs() {
        dispatcher.perform(.closeTerminal)

        XCTAssertTrue(shared.navigation.openTabs.isEmpty)
        XCTAssertTrue(terminalService.killedIDs.isEmpty)
    }
}
