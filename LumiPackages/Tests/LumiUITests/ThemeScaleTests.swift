import XCTest
@testable import LumiUI

/// Arayüz ölçeğinin (karar 57) token'lara indiğini kilitler.
///
/// Bu testlerin varlık sebebi: ölçek ÇİZİMİ değil **token'ları** büyütür —
/// layout bu sayede gerçekten yeniden akar (Chromium page zoom paritesi).
/// Bir token ölçekten kaçarsa (ör. `static let` olarak donarsa) arayüz
/// zoom'da tutarsız görünür ve bunu gözle yakalamak zordur.
@MainActor
final class ThemeScaleTests: XCTestCase {
    override func tearDown() {
        Theme.uiScale = 1
    }

    func testDefaultScaleIsActualSize() {
        XCTAssertEqual(Theme.uiScale, 1)
        XCTAssertEqual(Theme.scaled(13), 13)
    }

    func testSpacingAndRadiusFollowTheScale() {
        let spacing = Theme.Spacing.md
        let radius = Theme.Radius.lg

        Theme.uiScale = 1.5

        XCTAssertEqual(Theme.Spacing.md, spacing * 1.5)
        XCTAssertEqual(Theme.Radius.lg, radius * 1.5)
    }

    func testRowAndStrokeFollowTheScale() {
        let row = Theme.Row.compact
        let stroke = Theme.Stroke.hairline

        Theme.uiScale = 2

        XCTAssertEqual(Theme.Row.compact, row * 2)
        XCTAssertEqual(Theme.Stroke.hairline, stroke * 2)
    }

    /// Sıfır token'ı (tam genişlik satırın köşesi) ölçekten etkilenmez.
    func testZeroRadiusStaysZero() {
        Theme.uiScale = 2
        XCTAssertEqual(Theme.Radius.none, 0)
    }

    /// Bar yükseklikleri de ölçeklenir — yoksa büyüyen punto sabit yükseklikli
    /// bir barda kırpılırdı.
    func testBarMetricsFollowTheScale() {
        let topBar = TopBarMetrics.height
        let statusBar = StatusBarMetrics.height

        Theme.uiScale = 1.25

        XCTAssertEqual(TopBarMetrics.height, topBar * 1.25)
        XCTAssertEqual(StatusBarMetrics.height, statusBar * 1.25)
    }

    /// Hazır fontlar (`Theme.Typography.body` vb.) `let` olsaydı ilk erişimdeki
    /// ölçekte donar, zoom onları atlardı.
    func testReadyMadeFontsAreRecomputedPerScale() {
        let atActualSize = Theme.Typography.body
        Theme.uiScale = 2
        XCTAssertNotEqual(Theme.Typography.body, atActualSize)
        Theme.uiScale = 1
        XCTAssertEqual(Theme.Typography.body, atActualSize)
    }

    /// Punto ölçeği ile tipografi BASAMAKLARI karışmamalı: basamak tanımları
    /// (`Size.body` = 12pt) ham kalır, ölçek yalnız fabrikada uygulanır.
    func testTypographyStepsStayRaw() {
        Theme.uiScale = 2
        XCTAssertEqual(Theme.Typography.Size.body.points, 12)
        XCTAssertEqual(Theme.scaled(Theme.Typography.Size.body.points), 24)
    }
}
