import XCTest
@testable import LumiUI

/// Arayüz ölçeğinin (karar 61) token'lara indiğini kilitler.
///
/// Bu testlerin varlık sebebi: ölçek ÇİZİMİ değil **token'ları** büyütür —
/// layout bu sayede gerçekten yeniden akar (Chromium page zoom paritesi).
/// Bir token ölçekten kaçarsa (ör. `static let` olarak donarsa) arayüz
/// zoom'da tutarsız görünür ve bunu gözle yakalamak zordur.
@MainActor
final class ThemeScaleTests: XCTestCase {
    override func tearDown() {
        Theme.uiScale = 1
        Theme.devicePixel = 0.5
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

    // MARK: - Cihaz pikseli yuvarlaması

    /// Yuvarlamanın varlık sebebi: %80'de HİÇBİR token piksele oturmuyordu
    /// (8 → 6.4, 1 → 0.8) ve metin taban çizgileri alt-piksel fazına düşüp
    /// "parıldıyordu". Bu test o regresyonu kilitler.
    func testMetricsSnapToTheDevicePixel() {
        Theme.uiScale = 0.8

        // 8 * 0.8 = 6.4 → 6.5 (Retina ızgarası 0.5pt)
        XCTAssertEqual(Theme.Spacing.md, 6.5)
        // 12 * 0.8 = 9.6 → 9.5
        XCTAssertEqual(Theme.Spacing.lg, 9.5)
        // 22 * 0.8 = 17.6 → 17.5
        XCTAssertEqual(Theme.Row.compact, 17.5)

        for value in [Theme.Spacing.md, Theme.Spacing.lg, Theme.Row.compact] {
            XCTAssertEqual((value / Theme.devicePixel).truncatingRemainder(dividingBy: 1), 0)
        }
    }

    /// Punto tam sayıya oturur — kesirli punto kesirli satır yüksekliği üretir
    /// ve hizalanmış bir kap bunu kurtaramaz.
    func testFontSizesSnapToWholePoints() {
        Theme.uiScale = 0.8

        XCTAssertEqual(Theme.scaledFontSize(12), 10) // 9.6
        XCTAssertEqual(Theme.scaledFontSize(11), 9)  // 8.8
        XCTAssertEqual(Theme.scaledFontSize(10), 8)  // 8.0
        XCTAssertEqual(Theme.scaledFontSize(13), 10) // 10.4
    }

    /// Izgara ekrandan gelir; 1x'te yuvarlama tam sayıya sıkılaşır.
    func testGridFollowsTheDevicePixel() {
        Theme.uiScale = 0.8
        Theme.devicePixel = 1

        XCTAssertEqual(Theme.Spacing.md, 6) // 6.4 → 6
        XCTAssertEqual(Theme.Spacing.lg, 10) // 9.6 → 10
    }

    /// Sıfırdan farklı bir ölçü asla sıfıra çökmez — bir kenarlık tamamen
    /// kaybolurdu. `Stroke.hairline` %80'de 0.8pt ediyor.
    func testHairlineNeverCollapsesToZero() {
        Theme.uiScale = 0.2
        XCTAssertEqual(Theme.Stroke.hairline, Theme.devicePixel)
        XCTAssertEqual(Theme.scaledFontSize(1), 1)
    }

    /// Piksele zaten oturan ölçekler yuvarlamadan etkilenmez (regresyon ağı:
    /// mevcut basamakların çoğu tam değer üretir).
    func testAlignedScalesAreUntouched() {
        Theme.uiScale = 1.5
        XCTAssertEqual(Theme.Spacing.md, 12)
        XCTAssertEqual(Theme.scaledFontSize(12), 18)
    }
}
