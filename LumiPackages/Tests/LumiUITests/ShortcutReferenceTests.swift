import LumiKit
import XCTest
@testable import LumiUI

/// Shortcuts sekmesi salt-okunur referansının bütünlüğü.
/// Liste MainMenuBuilder'ın görsel aynası — sapmaları erken yakalar.
final class ShortcutReferenceTests: XCTestCase {
    func testCoversEveryMenuShortcutAction() {
        let actions = Set(ShortcutReference.list().map(\.action))

        // MainMenuBuilder'daki kullanıcıya görünür kısayol aksiyonları
        let expected: Set<String> = [
            "New Terminal", "Close Terminal", "Open Repository", "Switch to Tab N",
            "Focus Terminal N", "Previous Terminal", "Next Terminal",
            "Maximize Terminal", "Toggle Left Sidebar", "Toggle Right Sidebar",
            "Focus Mode", "Zoom In", "Zoom Out", "Actual Size",
            "Settings", "Quit",
        ]

        XCTAssertEqual(actions, expected)
    }

    func testEveryComboIsNonEmpty() {
        // Repo tab geçişi ⌘'siz TEK kısayoldur (karar 59): ⌘1…⌘9 terminalde.
        for ref in ShortcutReference.list() {
            XCTAssertFalse(ref.combos.isEmpty, "\(ref.action) kombosuz")
            let expectedModifier = ref.action == "Switch to Tab N" ? "⌃" : "⌘"
            for combo in ref.combos {
                XCTAssertFalse(combo.isEmpty, "\(ref.action) boş kombo içeriyor")
                XCTAssertTrue(
                    combo.contains(expectedModifier),
                    "\(ref.action) \(expectedModifier) taşımıyor"
                )
            }
        }
    }

    func testRangeShortcutHasTwoCombos() {
        let tabN = ShortcutReference.list().first { $0.action == "Switch to Tab N" }
        XCTAssertEqual(tabN?.combos.count, 2, "aralıklı kısayol iki kombo (⌃1 – ⌃9) olmalı")
    }

    /// Karar 62: tablo menüyle aynı düzenden türer — takas edilince satırların
    /// etiketleri aynı kalır, YALNIZ indeksli iki ailenin sembolü yer değiştirir.
    func testSwappedStyleSwapsOnlyTheIndexedRows() {
        let swapped = ShortcutReference.list(style: .repoOnCommand)
        XCTAssertEqual(swapped.map(\.action), ShortcutReference.list().map(\.action))
        XCTAssertEqual(
            swapped.first { $0.action == "Switch to Tab N" }?.combos,
            [["⌘", "1"], ["⌘", "9"]]
        )
        XCTAssertEqual(
            swapped.first { $0.action == "Focus Terminal N" }?.combos,
            [["⌃", "1"], ["⌃", "9"]]
        )
    }

    func testActionsAreUnique() {
        let actions = ShortcutReference.list().map(\.action)
        XCTAssertEqual(actions.count, Set(actions).count, "aksiyon adları benzersiz olmalı")
    }
}
