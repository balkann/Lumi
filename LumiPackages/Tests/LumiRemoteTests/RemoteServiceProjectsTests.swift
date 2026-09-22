import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiRemote

// MARK: - FakeRelayConnection projects helpers

extension FakeRelayConnection {
    /// `projects` frame'indeki proje path'leri (Sendable [String] döner).
    func projectPaths() -> [String] {
        guard let payload = sent.first(where: { $0.type == "projects" })?.payload,
              let list = payload["projects"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["path"] as? String }
    }

    /// `projects` frame'indeki ilk projenin ilk checkout kind'ı (Sendable String? döner).
    func firstCheckoutKind() -> String? {
        guard let payload = sent.first(where: { $0.type == "projects" })?.payload,
              let list = payload["projects"] as? [[String: Any]],
              let first = list.first,
              let checkouts = first["checkouts"] as? [[String: Any]] else { return nil }
        return checkouts.first?["kind"] as? String
    }

    /// `projects` frame'indeki addable path'leri (Sendable [String] döner).
    func addablePaths() -> [String] {
        guard let payload = sent.first(where: { $0.type == "projects" })?.payload,
              let list = payload["addable"] as? [[String: String]] else { return [] }
        return list.compactMap { $0["path"] }
    }

    /// `projects` frame sayısı.
    func projectsCount() -> Int { sent.filter { $0.type == "projects" }.count }
}

// MARK: - Tests

/// Task 8: Mac → phone projects broadcast.
/// Favorited repo'dan `projects` frame'inin welcome'da yayınlanması.
@Suite @MainActor struct RemoteServiceProjectsTests {

    // MARK: - T1: welcome → projects frame yayınlanır (favorited repo)

    /// Bir favorited repo + welcome → projects frame gönderilmeli;
    /// payload'da proje path'i + "original" checkout bulunmalı.
    @Test func welcomeBroadcastsProjectsFromFavorites() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let repos = FakeRepoService(repos: [
            Repo(name: "unco", path: "/p/unco", isGitRepo: true, source: .standalone)
        ])
        let cfg = FakeConfigService()
        await cfg.seed(AppConfig(
            projectsRoot: "",
            additionalPaths: [],
            aiProvider: .claude,
            theme: "dark",
            terminalFontSize: 13,
            terminalFontFamily: "",
            terminalCursorStyle: "block",
            terminalCursorBlink: true,
            notifications: .defaults,
            sidebarProjectPaths: ["/p/unco"]
        ))

        let svc = RemoteService(
            paths: .testDefaults(), terminal: term, repos: repos,
            connection: conn, chatSource: FakeChatTranscriptSource(events: []),
            hookEvents: { AsyncStream { _ in } }, config: cfg
        )
        await svc.start()

        // Act: phone sends welcome
        await conn.injectInbound(type: "welcome", payload: [:])
        try await conn.waitForSent(types: ["projects"])

        // Assert: projects frame içeriği
        #expect(await conn.projectPaths() == ["/p/unco"])
        #expect(await conn.firstCheckoutKind() == "original")

        svc.stop()
    }

    // MARK: - T2: addable = repos - favorited

    /// Favorited olmayan repo → addable'da görünmeli.
    @Test func nonFavoritedRepoAppearsInAddable() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let repos = FakeRepoService(repos: [
            Repo(name: "fav", path: "/p/fav", isGitRepo: true, source: .standalone),
            Repo(name: "other", path: "/p/other", isGitRepo: false, source: .standalone),
        ])
        let cfg = FakeConfigService()
        await cfg.seed(AppConfig(
            projectsRoot: "",
            additionalPaths: [],
            aiProvider: .claude,
            theme: "dark",
            terminalFontSize: 13,
            terminalFontFamily: "",
            terminalCursorStyle: "block",
            terminalCursorBlink: true,
            notifications: .defaults,
            sidebarProjectPaths: ["/p/fav"]
        ))

        let svc = RemoteService(
            paths: .testDefaults(), terminal: term, repos: repos,
            connection: conn, chatSource: FakeChatTranscriptSource(events: []),
            hookEvents: { AsyncStream { _ in } }, config: cfg
        )
        await svc.start()
        await conn.injectInbound(type: "welcome", payload: [:])
        try await conn.waitForSent(types: ["projects"])

        let addable = await conn.addablePaths()
        #expect(addable.contains("/p/other"))
        #expect(!addable.contains("/p/fav"))

        svc.stop()
    }

    // MARK: - T3: boş favorites → projects: []

    /// Favorites boşken projects frame gönderilmeli, projects: [] olmalı.
    @Test func emptyFavoritesSendsEmptyProjectsList() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let repos = FakeRepoService(repos: [
            Repo(name: "r", path: "/p/r", isGitRepo: true, source: .standalone)
        ])
        let cfg = FakeConfigService() // defaults → sidebarProjectPaths: []

        let svc = RemoteService(
            paths: .testDefaults(), terminal: term, repos: repos,
            connection: conn, chatSource: FakeChatTranscriptSource(events: []),
            hookEvents: { AsyncStream { _ in } }, config: cfg
        )
        await svc.start()
        await conn.injectInbound(type: "welcome", payload: [:])
        try await conn.waitForSent(types: ["projects"])

        #expect(await conn.projectPaths().isEmpty)

        svc.stop()
    }
}
