import Testing
import Foundation
@testable import LumiServices

@Suite struct TranscriptLocatorTests {
    @Test func picksMostRecentTranscript() {
        let locator = TranscriptLocator(fileList: { _ in
            [("older", Date(timeIntervalSince1970: 100)),
             ("newer", Date(timeIntervalSince1970: 200))]
        })
        #expect(locator.locate(repoPath: "/Users/x/repo") == "newer")
    }
    @Test func returnsNilWhenEmpty() {
        let locator = TranscriptLocator(fileList: { _ in [] })
        #expect(locator.locate(repoPath: "/Users/x/repo") == nil)
    }
    @Test func encodesRepoPathForLookup() {
        // @Sendable closure: mutable capture nonisolated(unsafe) ile işaretlenir.
        nonisolated(unsafe) var seen: String?
        let locator = TranscriptLocator(fileList: { encoded in seen = encoded; return [] })
        _ = locator.locate(repoPath: "/Users/x/My Repo!")
        #expect(seen == "-Users-x-My-Repo-")
    }
}
