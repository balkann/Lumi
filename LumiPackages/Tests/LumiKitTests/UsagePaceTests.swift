import LumiKit
import XCTest

/// Tempo aritmetiği (karar 85). Renk eşlemesi LumiUI'da
/// (`UsagePaceColorTests`); burada yalnız saf sayılar kilitlenir.
final class UsagePaceTests: XCTestCase {
    private func pace(_ percent: Int?, elapsed: Double?) -> UsagePace? {
        UsagePace(percentUsed: percent, elapsedFraction: elapsed)
    }

    func testPaceNeedsBothAxes() {
        XCTAssertNil(pace(nil, elapsed: 0.4))
        XCTAssertNil(pace(40, elapsed: nil))
        XCTAssertNotNil(pace(40, elapsed: 0.4))
    }

    func testElapsedFractionBecomesPointsOnTheSameScaleAsPercent() {
        XCTAssertEqual(pace(12, elapsed: 0.4)?.elapsedPoints, 40)
        XCTAssertEqual(pace(12, elapsed: 0.4)?.deltaPoints, -28)
        XCTAssertEqual(pace(70, elapsed: 0.4)?.deltaPoints, 30)
        // Bayat snapshot / saat kayması: kesir 0–1'e kırpılır.
        XCTAssertEqual(pace(12, elapsed: 1.8)?.elapsedPoints, 100)
        XCTAssertEqual(pace(12, elapsed: -0.5)?.elapsedPoints, 0)
    }

    func testToleranceBandAroundTheMarkerStaysNeutral() {
        // ±5 puan: çizginin yakını "tempoda"dır, renk titremez.
        XCTAssertEqual(pace(40, elapsed: 0.40)?.toneStop, 0)
        XCTAssertEqual(pace(45, elapsed: 0.40)?.toneStop, 0)
        XCTAssertEqual(pace(35, elapsed: 0.40)?.toneStop, 0)
    }

    func testFallingBehindWalksTowardTheCoolEnd() {
        // Tolerans kenarının hemen dışı: rampa yeni başlıyor.
        XCTAssertEqual(pace(34, elapsed: 0.40)?.toneStop ?? 0, -1 / 25, accuracy: 0.0001)
        // Kenardan `coolSpan` (25) puan geride → tam soğuk uç.
        XCTAssertEqual(pace(10, elapsed: 0.40)?.toneStop ?? 0, -1, accuracy: 0.0001)
        // Daha da geride kalmak uçtan öteye gitmez.
        XCTAssertEqual(pace(0, elapsed: 0.40)?.toneStop ?? 0, -1, accuracy: 0.0001)
    }

    func testRunningAheadWalksTowardTheCriticalEnd() {
        // Sıcak taraf daha geniştir (40 puan): uyarıya geçmek daha çok kanıt ister.
        XCTAssertEqual(pace(46, elapsed: 0.40)?.toneStop ?? 0, 1 / 40, accuracy: 0.0001)
        XCTAssertEqual(pace(65, elapsed: 0.40)?.toneStop ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(pace(85, elapsed: 0.40)?.toneStop ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(pace(99, elapsed: 0.40)?.toneStop ?? 0, 1, accuracy: 0.0001)
    }

    func testExhaustedLimitIsCriticalWhateverThePaceSays() {
        // Pencere neredeyse bittiği için "tempoda" görünür — ama kota bitmiştir.
        XCTAssertEqual(pace(100, elapsed: 0.99)?.toneStop, 1)
        XCTAssertEqual(pace(100, elapsed: 1.0)?.toneStop, 1)
    }
}
