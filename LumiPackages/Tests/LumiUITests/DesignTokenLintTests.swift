import Foundation
import XCTest
@testable import LumiUI

/// Token disiplininin kaynak-üstü kapısı (Faz 7.1).
///
/// Faz 7'nin ikinci dalgasında göç TAMAMLANDI: modülde artık tek bir literal
/// punto ya da köşe yarıçapı yok. Eşikler bu yüzden bir "bütçe" değil,
/// **sıfır**: yeni bir `.font(.system(size: …))` ya da `cornerRadius: 12`
/// eklenirse test kırmızıya döner ve `Theme.Typography` / `Theme.Radius`
/// kullanılması gerektiğini söyler.
final class DesignTokenLintTests: XCTestCase {
    /// `Sources/LumiUI` dizini — testin kendi konumundan türetilir.
    private static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)        // Tests/LumiUITests/DesignTokenLintTests.swift
            .deletingLastPathComponent()       // Tests/LumiUITests
            .deletingLastPathComponent()       // Tests
            .deletingLastPathComponent()       // LumiPackages
            .appendingPathComponent("Sources/LumiUI")
    }

    /// `.font(.system(size: …))` — göç tamamlandı, kalan sayı sıfır.
    private static let fontLiteralBudget = 0

    /// `cornerRadius: <sayı>` — göç tamamlandı, kalan sayı sıfır.
    private static let radiusLiteralBudget = 0

    private static let fontLiteral = try! NSRegularExpression(
        pattern: #"\.font\(\.system\(size:"#
    )
    private static let radiusLiteral = try! NSRegularExpression(
        pattern: #"cornerRadius:\s*\(?[0-9]"#
    )

    // MARK: - Testler

    func testModuleContainsNoFontSizeLiterals() throws {
        XCTAssertEqual(
            try scan(Self.fontLiteral), [:],
            "Literal punto kaldı — Theme.Typography kullan"
        )
    }

    func testModuleContainsNoCornerRadiusLiterals() throws {
        XCTAssertEqual(
            try scan(Self.radiusLiteral), [:],
            "Literal köşe yarıçapı kaldı — Theme.Radius kullan"
        )
    }

    func testFontSizeLiteralBudgetIsZero() throws {
        let total = try scan(Self.fontLiteral).values.reduce(0, +)
        XCTAssertEqual(
            total, Self.fontLiteralBudget,
            "Yeni literal punto eklendi; Theme.Typography kullan"
        )
    }

    func testCornerRadiusLiteralBudgetIsZero() throws {
        let total = try scan(Self.radiusLiteral).values.reduce(0, +)
        XCTAssertEqual(
            total, Self.radiusLiteralBudget,
            "Yeni literal köşe yarıçapı eklendi; Theme.Radius kullan"
        )
    }

    // MARK: - Yardımcı

    /// Dosya adı → eşleşme sayısı (yalnız eşleşen dosyalar).
    private func scan(_ regex: NSRegularExpression) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for url in try Self.swiftFiles() {
            // Token tanımlarının kendisi (Theme+Typography) sayılmaz.
            guard url.lastPathComponent != "Theme+Typography.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let matches = regex.numberOfMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            )
            if matches > 0 { counts[url.lastPathComponent] = matches }
        }
        return counts
    }

    // MARK: - Ölçeklenmeyen metrikler (karar 61)

    /// Boşluk / dolgu / frame / metrik sabiti literalleri — hepsi sıfır.
    ///
    /// **Neden ayrı bir kapı:** yukarıdaki iki kural yalnız puntoyu ve köşe
    /// yarıçapını kapatıyordu, oysa arayüz zoom'u (karar 61) `Theme.scaled`'den
    /// GEÇEN her ölçüye iner. Literal kalan bir boşluk ya da frame ölçekten
    /// kaçar: %80'de yazı küçülürken kutusu tam boyutta kalır, pencere yarı
    /// ölçeklenmiş görünür. Bu tam olarak yaşandı — modüle 125 kaçak birikmişti
    /// ve hiçbiri testlere takılmamıştı.
    ///
    /// `static let` yerine `static var … { Theme.scaled(N) }` gerekir: `let`
    /// ilk erişimdeki ölçekte donar ve zoom onu atlar.
    ///
    /// Kapsam dışı: sıfır (ölçeklense de sıfırdır), `#if DEBUG` preview
    /// blokları, `…Ratio`/`…Scale` adlı oranlar (pencereye göre kesir
    /// verirler, punto/mesafe değildirler) ve `PreferenceKey.defaultValue`.
    private static let unscaledMetric = try! NSRegularExpression(
        pattern: [
            #"\bspacing:\s*[1-9]"#,
            #"\.padding\(\s*(?:\.\w+\s*,\s*)?[1-9]"#,
            #"\b(?:width|height|minWidth|maxWidth|minHeight|maxHeight|idealWidth|idealHeight):\s*[1-9]"#,
            #"static\s+let\s+(?!\w*(?:Ratio|Scale)\b|defaultValue\b)\w+\s*:\s*CGFloat\s*=\s*[1-9]"#,
        ].joined(separator: "|")
    )

    func testModuleContainsNoUnscaledMetrics() throws {
        XCTAssertEqual(
            try scanSkippingPreviews(Self.unscaledMetric), [:],
            "Ölçeklenmeyen metrik literali kaldı — Theme.scaled / Theme.Spacing kullan (karar 61)"
        )
    }

    /// `scan` ile aynı, ama `#if DEBUG` preview blokları sayılmaz: preview
    /// kapları ekranda görünmez, ölçeklenmeleri de gerekmez.
    private func scanSkippingPreviews(_ regex: NSRegularExpression) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for url in try Self.swiftFiles() {
            guard !url.path.contains("/Theme/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            var inDebug = false
            var matches = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if DEBUG") { inDebug = true; continue }
                if trimmed.hasPrefix("#endif") { inDebug = false; continue }
                guard !inDebug, !trimmed.hasPrefix("//") else { continue }
                let s = String(line)
                matches += regex.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
            }
            if matches > 0 { counts[url.lastPathComponent] = matches }
        }
        return counts
    }

    private static func swiftFiles() throws -> [URL] {
        let directory = sourceDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            throw LintError.sourceDirectoryMissing(directory.path)
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    private enum LintError: Error {
        case sourceDirectoryMissing(String)
    }
}
