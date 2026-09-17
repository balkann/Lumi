import AppKit
import LumiKit
import SwiftUI
import XCTest
@testable import LumiUI

/// Arayüz yazı tipinin (karar 59) token'lara indiğini kilitler.
///
/// Bu testlerin varlık sebebi: `Font.custom` KAYITSIZ bir adda hata vermez —
/// sessizce orantılı sistem fontuna düşer. Böyle bir sapma derlemede değil,
/// yalnız gözle fark edilir ve monospace hizasına dayanan her yerleşimi bozar.
@MainActor
final class ThemeUIFontTests: XCTestCase {
    override func setUp() {
        LumiFonts.registerBundledFonts()
    }

    override func tearDown() {
        Theme.uiFontFamily = .system
    }

    func testDefaultFamilyIsSystemMono() {
        XCTAssertEqual(Theme.uiFontFamily, .system)
        XCTAssertEqual(
            Theme.Typography.mono(.body),
            .system(size: Theme.Typography.Size.body.points, weight: .regular, design: .monospaced)
        )
    }

    /// Dört ağırlığın DE bundle'da olması `isBundledUIFontAvailable`'ın ön
    /// koşulu; biri eksikse `Theme` sistem yüzüne düşer ve ayar sessizce
    /// etkisiz kalırdı.
    func testBundledFacesCoverEveryWeightTheUIUses() {
        for name in [
            LumiFonts.regularName,
            LumiFonts.mediumName,
            LumiFonts.semiBoldName,
            LumiFonts.boldName,
        ] {
            XCTAssertNotNil(NSFont(name: name, size: 12), "\(name) kayıtlı değil")
        }
        XCTAssertTrue(LumiFonts.isBundledUIFontAvailable)
    }

    /// Ağırlık sentetik kalınlaştırmayla değil ayrı yüzlerle karşılanır —
    /// Electron'un Google Fonts'tan çektiği 400/500/600/700 kümesinin aynısı.
    func testWeightsMapToDistinctFaces() {
        XCTAssertEqual(LumiFonts.uiPostScriptName(for: .regular), LumiFonts.regularName)
        XCTAssertEqual(LumiFonts.uiPostScriptName(for: .medium), LumiFonts.mediumName)
        XCTAssertEqual(LumiFonts.uiPostScriptName(for: .semibold), LumiFonts.semiBoldName)
        XCTAssertEqual(LumiFonts.uiPostScriptName(for: .bold), LumiFonts.boldName)
        // Ölçeğin uçları da kayıtlı bir yüze düşer, sentetiğe değil.
        XCTAssertEqual(LumiFonts.uiPostScriptName(for: .black), LumiFonts.boldName)
        XCTAssertEqual(LumiFonts.uiPostScriptName(for: .thin), LumiFonts.regularName)
    }

    func testSwitchingFamilyChangesEveryMonoToken() {
        let systemBody = Theme.Typography.mono(.body)
        let systemLabel = Theme.Typography.labelMono

        Theme.uiFontFamily = .jetBrainsMono

        XCTAssertNotEqual(Theme.Typography.mono(.body), systemBody)
        XCTAssertNotEqual(Theme.Typography.labelMono, systemLabel)
        XCTAssertEqual(
            Theme.Typography.mono(.body, weight: .semibold),
            .custom(LumiFonts.semiBoldName, fixedSize: Theme.Typography.Size.body.points)
        )
    }

    /// Yüz seçimi ölçekten (karar 57) bağımsızdır: ikisi de aynı fabrikadan
    /// geçer, biri diğerini yutmaz.
    ///
    /// Beklenen punto ÇARPIM DEĞİL yuvarlanmış değerdir: 13 * 1.5 = 19.5 ve
    /// `scaledFontSize` puntoyu tam sayıya oturtur (20). Kesirli punto kesirli
    /// satır yüksekliği üretip metni alt-piksel fazına düşürüyordu.
    func testFamilyAndScaleCompose() {
        Theme.uiFontFamily = .jetBrainsMono
        Theme.uiScale = 1.5
        defer { Theme.uiScale = 1 }

        XCTAssertEqual(
            Theme.Typography.mono(.base),
            .custom(LumiFonts.regularName, fixedSize: 20)
        )
    }

    /// SF Mono seçiliyken `Font.custom` hiç devreye girmez — eski davranış
    /// birebir korunur.
    func testSystemFamilyIgnoresBundledFaces() {
        Theme.uiFontFamily = .system
        XCTAssertEqual(
            Theme.Typography.mono(.label, weight: .semibold),
            .system(size: Theme.Typography.Size.label.points, weight: .semibold, design: .monospaced)
        )
    }
}
