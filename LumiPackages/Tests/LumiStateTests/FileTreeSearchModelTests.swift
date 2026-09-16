import Foundation
import LumiKit
import XCTest
@testable import LumiState

/// `FileTreeSearchModel` — file-tree arama kutusunun debounce/iptal durum
/// makinesi (refactor 6.7: eskiden `FileTreeSidebar`'ın `@State`'iydi).
@MainActor
final class FileTreeSearchModelTests: XCTestCase {
    /// Arama closure'ı MainActor DIŞINDA koştuğu için çağrı kaydı actor'da tutulur.
    private actor SearchSpy {
        private(set) var queries: [String] = []

        func record(_ query: String) {
            queries.append(query)
        }

        var callCount: Int { queries.count }
        var last: String? { queries.last }
    }

    private let debounce: Duration = .milliseconds(20)

    private let tree = [
        FileTreeNode(name: "src", path: "src", type: .folder, isIgnored: false, children: [
            FileTreeNode(name: "main.swift", path: "src/main.swift", type: .file, isIgnored: false, children: []),
        ]),
    ]

    /// Sorguyu sonuca çeviren sahte filtre; her çağrıyı spy'a yazar.
    private func makeModel(spy: SearchSpy) -> FileTreeSearchModel<[String]> {
        FileTreeSearchModel(debounce: debounce) { nodes, query in
            Task { await spy.record(query) }
            return nodes.map { "\($0.path):\(query)" }
        }
    }

    private func settle() async {
        try? await Task.sleep(for: debounce * 6)
    }

    /// Yüklü CI runner'ında 20 ms'lik debounce penceresi sabit uykuyla
    /// yakalanamıyor (task planlaması gecikiyor). Bir şeyin OLMASINI bekleyen
    /// assert'ler koşula kadar yoklar; sabit uyku yalnız bir şeyin OLMAMASINI
    /// doğrulayan testlerde kalır.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("zaman aşımı: \(description)")
    }

    // MARK: - Debounce

    func testRapidTypingRunsSearchOnce() async {
        let spy = SearchSpy()
        let model = makeModel(spy: spy)

        model.setQuery("m", tree: tree)
        model.setQuery("ma", tree: tree)
        model.setQuery("mai", tree: tree)
        await waitUntil("debounce penceresi kapanmalı") { await spy.callCount >= 1 }
        await settle() // pencere kapandıktan sonra ikinci bir arama doğmadığını da görelim

        let count = await spy.callCount
        let last = await spy.last
        XCTAssertEqual(count, 1, "debounce penceresinde tek arama koşar")
        XCTAssertEqual(last, "mai")
        XCTAssertEqual(model.results, ["src:mai"])
    }

    func testQueryIsVisibleImmediatelyBeforeDebounceFires() {
        let model = makeModel(spy: SearchSpy())

        model.setQuery("main", tree: tree)

        XCTAssertEqual(model.query, "main", "TextField anında güncellenir")
        XCTAssertNil(model.results, "sonuç henüz yok — view normal ağacı çizer")
    }

    // MARK: - İptal

    func testNewQueryCancelsPreviousSearch() async {
        let spy = SearchSpy()
        let model = makeModel(spy: spy)

        model.setQuery("first", tree: tree)
        await waitUntil("ilk pencere kapanmalı") { await spy.callCount >= 1 }
        model.setQuery("second", tree: tree)
        await waitUntil("ikinci pencere kapanmalı") { await spy.callCount >= 2 }

        let queries = await spy.queries
        XCTAssertEqual(queries, ["first", "second"], "her tamamlanan pencere bir kez koşar")
        XCTAssertEqual(model.results, ["src:second"], "sonuç SON sorgunun sonucudur")
    }

    func testCancelStopsInFlightSearchAndClearsState() async {
        let spy = SearchSpy()
        let model = makeModel(spy: spy)

        model.setQuery("main", tree: tree)
        model.cancel()
        await settle()

        let count = await spy.callCount
        XCTAssertEqual(count, 0, "debounce dolmadan iptal edilen arama hiç koşmaz")
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.results)
        XCTAssertFalse(model.isSearching)
    }

    // MARK: - Boş sorgu

    func testEmptyQueryClearsResultsWithoutSearching() async {
        let spy = SearchSpy()
        let model = makeModel(spy: spy)

        model.setQuery("main", tree: tree)
        await waitUntil("ilk arama sonuç üretmeli") { model.results != nil }

        model.setQuery("", tree: tree)
        await settle()

        XCTAssertNil(model.results, "boş sorgu sonuçları temizler")
        XCTAssertFalse(model.isSearching)
        let count = await spy.callCount
        XCTAssertEqual(count, 1, "boş sorgu için arama koşmaz")
    }

    func testWhitespaceOnlyQueryCountsAsEmpty() async {
        let spy = SearchSpy()
        let model = makeModel(spy: spy)

        model.setQuery("   ", tree: tree)
        await settle()

        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.results)
        let count = await spy.callCount
        XCTAssertEqual(count, 0)
    }

    func testSearchReceivesTrimmedQuery() async {
        let spy = SearchSpy()
        let model = makeModel(spy: spy)

        model.setQuery("  main  ", tree: tree)
        await waitUntil("arama koşmalı") { await spy.callCount >= 1 }

        let last = await spy.last
        XCTAssertEqual(last, "main")
        XCTAssertEqual(model.query, "  main  ", "ham sorgu kullanıcının yazdığıdır")
    }

    // MARK: - Ağaç tazelenmesi

    func testRefreshedTreeReRunsSameQuery() async {
        let spy = SearchSpy()
        let model = makeModel(spy: spy)

        model.setQuery("main", tree: tree)
        await waitUntil("ilk arama sonuç üretmeli") { model.results == ["src:main"] }

        let grown = tree + [
            FileTreeNode(name: "docs", path: "docs", type: .folder, isIgnored: false, children: []),
        ]
        model.setQuery(model.query, tree: grown)
        await waitUntil("tazelenen ağaç yeniden aranmalı") {
            model.results == ["src:main", "docs:main"]
        }

        XCTAssertEqual(model.results, ["src:main", "docs:main"], "watcher tazelemesi sonucu günceller")
    }
}
