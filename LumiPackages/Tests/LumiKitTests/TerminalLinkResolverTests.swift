import Foundation
import XCTest
@testable import LumiKit

/// Karar 57: ham link metni → hedef çözümlemesi (saf tablo).
final class TerminalLinkResolverTests: XCTestCase {
    private let base = "/Users/dev/proj"
    private let home = "/Users/dev"
    private let roots = ["/Users/dev/proj", "/Users/dev/work/site"]

    private func resolve(
        _ link: String,
        directories: Set<String> = [],
        files: Set<String> = []
    ) -> TerminalLinkTarget? {
        TerminalLinkResolver.resolve(
            link: link,
            basePath: base,
            homeDirectory: home,
            knownRoots: roots,
            pathKind: { path in
                if directories.contains(path) { return .directory }
                return files.contains(path) ? .file : .missing
            }
        )
    }

    func testHTTPLinksBecomeURLs() {
        XCTAssertEqual(resolve("https://lumi.dev/docs"), .url(URL(string: "https://lumi.dev/docs")!))
    }

    /// Tarayıcıya gitmeyecek şemalar hiç eylem üretmez.
    func testNonWebSchemesAreIgnored() {
        XCTAssertNil(resolve("ssh://host/tmp"))
        XCTAssertNil(resolve("mailto:a@b.com"))
    }

    func testRelativePathResolvesAgainstTerminalDirectory() {
        XCTAssertEqual(
            resolve("src/App.swift", files: ["/Users/dev/proj/src/App.swift"]),
            .file(path: "/Users/dev/proj/src/App.swift")
        )
    }

    func testTildeAndDotSegmentsAreNormalized() {
        XCTAssertEqual(
            resolve("~/notes/todo.md", files: ["/Users/dev/notes/todo.md"]),
            .file(path: "/Users/dev/notes/todo.md")
        )
        XCTAssertEqual(
            resolve("./src/../README.md", files: ["/Users/dev/proj/README.md"]),
            .file(path: "/Users/dev/proj/README.md")
        )
    }

    /// Derleyici/test çıktısındaki `:satır:sütun` eki ayıklanır.
    func testLineAndColumnSuffixIsStripped() {
        XCTAssertEqual(
            resolve("src/App.swift:42:7", files: ["/Users/dev/proj/src/App.swift"]),
            .file(path: "/Users/dev/proj/src/App.swift")
        )
    }

    func testKnownRootBecomesWorkspace() {
        XCTAssertEqual(resolve("/Users/dev/work/site"), .workspace(path: "/Users/dev/work/site"))
        XCTAssertEqual(
            resolve("/Users/dev/work/site/"), .workspace(path: "/Users/dev/work/site"),
            "sondaki eğik çizgi kökü kaçırmamalı"
        )
    }

    func testUnknownDirectoryIsDirectory() {
        XCTAssertEqual(
            resolve("/tmp/logs", directories: ["/tmp/logs"]),
            .directory(path: "/tmp/logs")
        )
    }

    /// Diskte olmayan yol yine dosyadır: hata eylem çalışınca görünür (karar 5).
    func testMissingPathStaysAFile() {
        XCTAssertEqual(resolve("build/out.o"), .file(path: "/Users/dev/proj/build/out.o"))
    }

    func testSurroundingPunctuationIsTrimmed() {
        XCTAssertEqual(
            resolve("(src/App.swift)", files: ["/Users/dev/proj/src/App.swift"]),
            .file(path: "/Users/dev/proj/src/App.swift")
        )
    }

    func testEnclosingRootPicksTheDeepestMatch() {
        let root = TerminalLinkResolver.enclosingRoot(
            of: "/Users/dev/proj/nested/src/App.swift",
            in: ["/Users/dev/proj", "/Users/dev/proj/nested"]
        )
        XCTAssertEqual(root, "/Users/dev/proj/nested")
        XCTAssertEqual(
            TerminalLinkResolver.relativePath(of: "/Users/dev/proj/nested/src/App.swift", in: root!),
            "src/App.swift"
        )
    }

    /// Karar 67: `standardizingPath` var olan `/private/...` yollarından
    /// `/private`'ı atıyordu; popover başlığı terminaldeki metinle aynı kalmalı.
    func testPrivatePrefixIsPreserved() {
        let path = "/private/tmp/claude-502/scratchpad/b_side.png"
        XCTAssertEqual(resolve(path, files: [path]), .file(path: path))
        XCTAssertEqual(
            resolve("/private/tmp/./claude-502/x/../scratchpad", directories: ["/private/tmp/claude-502/scratchpad"]),
            .directory(path: "/private/tmp/claude-502/scratchpad")
        )
    }

    func testEnclosingRootRejectsSiblingPrefixes() {
        XCTAssertNil(TerminalLinkResolver.enclosingRoot(
            of: "/Users/dev/projector/App.swift", in: ["/Users/dev/proj"]
        ))
    }
}
