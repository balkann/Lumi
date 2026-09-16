import Foundation
import LumiKit
@testable import LumiState
import LumiTestSupport
import XCTest

/// Karar 54: Settings ▸ Agent ▸ DeepSeek durumu ve terminal açma kapısı.
@MainActor
final class DeepSeekStoreTests: XCTestCase {
    private func makeStore(
        apiKey: String? = nil
    ) -> (store: DeepSeekStore, service: FakeDeepSeekEnvironmentService, toasts: ToastStore) {
        let service = FakeDeepSeekEnvironmentService(apiKey: apiKey)
        let toasts = ToastStore(autoDismissAfter: 60)
        return (DeepSeekStore(service: service, toasts: toasts), service, toasts)
    }

    func testLoadSeedsTheDraftWithTheInstalledKey() async {
        let (store, _, _) = makeStore(apiKey: "sk-installed")

        await store.load()

        XCTAssertTrue(store.isInstalled)
        XCTAssertEqual(store.apiKeyDraft, "sk-installed")
        XCTAssertFalse(store.hasUnsavedKey)
    }

    func testLoadLeavesAnEmptyDraftWhenNothingIsInstalled() async {
        let (store, _, _) = makeStore()

        await store.load()

        XCTAssertFalse(store.isInstalled)
        XCTAssertEqual(store.apiKeyDraft, "")
        XCTAssertFalse(store.canInstall)
    }

    func testInstallWritesTheDraftAndReportsSuccess() async {
        let (store, service, toasts) = makeStore()
        await store.load()
        store.apiKeyDraft = "sk-new"

        XCTAssertTrue(store.canInstall)
        await store.install()

        let installed = await service.installedKeys
        XCTAssertEqual(installed, ["sk-new"])
        XCTAssertTrue(store.isInstalled)
        XCTAssertFalse(store.hasUnsavedKey)
        XCTAssertEqual(toasts.toasts.map(\.kind), [.success])
    }

    func testInstallIsBlockedForAShellUnsafeDraft() async {
        let (store, service, toasts) = makeStore()
        store.apiKeyDraft = "sk-$(whoami)"

        XCTAssertFalse(store.canInstall)
        await store.install()

        let installed = await service.installedKeys
        XCTAssertTrue(installed.isEmpty)
        XCTAssertTrue(toasts.toasts.isEmpty)
    }

    func testInstallFailureSurfacesAnErrorToastAndKeepsTheDraft() async {
        let (store, service, toasts) = makeStore()
        await service.setFailure(LumiError.configIOFailed(file: "x", detail: "disk full"))
        store.apiKeyDraft = "sk-fails"

        await store.install()

        XCTAssertFalse(store.isInstalled)
        XCTAssertEqual(store.apiKeyDraft, "sk-fails")
        XCTAssertEqual(toasts.toasts.map(\.kind), [.error])
    }

    func testRemoveClearsTheDraftAndTheSetup() async {
        let (store, service, toasts) = makeStore(apiKey: "sk-old")
        await store.load()

        await store.remove()

        let removeCount = await service.removeCount
        XCTAssertEqual(removeCount, 1)
        XCTAssertFalse(store.isInstalled)
        XCTAssertEqual(store.apiKeyDraft, "")
        XCTAssertEqual(toasts.toasts.map(\.kind), [.info])
    }

    func testHasUnsavedKeyTracksDraftDivergence() async {
        let (store, _, _) = makeStore(apiKey: "sk-saved")
        await store.load()

        store.apiKeyDraft = "sk-edited"

        XCTAssertTrue(store.hasUnsavedKey)
    }

    func testLaunchCommandOrWarnRefusesWhenNotConfigured() async {
        let (store, _, toasts) = makeStore()
        await store.load()

        XCTAssertNil(store.launchCommandOrWarn())
        XCTAssertEqual(toasts.toasts.map(\.kind), [.info])
    }

    func testLaunchCommandSourcesTheEnvFileWhenConfigured() async {
        let (store, _, toasts) = makeStore(apiKey: "sk-ready")
        await store.load()

        XCTAssertEqual(
            store.launchCommandOrWarn(),
            "source \"/tmp/lumi-tests/.claude/deepseek.env\" && claude"
        )
        XCTAssertTrue(toasts.toasts.isEmpty)
    }
}
