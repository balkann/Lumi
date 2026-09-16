import Foundation
import XCTest
import LumiKit
import LumiTestSupport
@testable import LumiServices

final class PlasticWorkspaceCreationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("lumi-plastic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source/.plastic"), withIntermediateDirectories: true)
        try "rep \"game@team@cloud\"\n path \"/\"\n smartbranch \"/main/release\" changeset \"42\"".write(to: root.appendingPathComponent("source/.plastic/plastic.selector"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCreatesBranchAtSourceRevisionAndSwitchesOnlyNewWorkspace() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path)
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: root.appendingPathComponent("workspaces"))
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        let result = try await service.create(WorkspaceCreateRequest(project: project, name: "Review"))
        XCTAssertEqual(result.workspace.scm, .plastic)
        XCTAssertEqual(result.workspace.branch, "/main/release/Review")
        XCTAssertTrue(result.workspace.path.hasSuffix("/workspaces/Game/Review"))
        let mutations = await runner.mutations
        XCTAssertEqual(mutations.count, 3)
        XCTAssertEqual(mutations[0].args, ["branch", "create", "br:/main/release/Review@game@team@cloud", "--changeset=cs:42@game@team@cloud", "-c=Created by Lumi"])
        XCTAssertEqual(mutations[0].cwd, project.path)
        XCTAssertEqual(mutations[1].args.suffix(2), [result.workspace.path, "game@team@cloud"])
        XCTAssertEqual(mutations[2].args, ["switch", "br:/main/release/Review@game@team@cloud", "--workspace=\(result.workspace.path)", "--noinput"])
        XCTAssertEqual(mutations[2].cwd, result.workspace.path)
    }

    func testReusesCurrentBranchWithoutCreatingAnotherBranch() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path)
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: root.appendingPathComponent("workspaces"))
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        let result = try await service.create(WorkspaceCreateRequest(project: project, name: "Review", branchName: "/ignored", branchMode: .current))
        XCTAssertEqual(result.workspace.branch, "/main/release")
        let mutations = await runner.mutations
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(mutations[0].args.suffix(2), [result.workspace.path, "game@team@cloud"])
        XCTAssertEqual(mutations[1].args, ["switch", "br:/main/release@game@team@cloud", "--workspace=\(result.workspace.path)", "--noinput"])
        XCTAssertEqual(mutations[1].cwd, result.workspace.path)
    }

    func testSwitchFailureKeepsPartialWorkspaceAndReportsRecoveryLocation() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path, failSwitch: true)
        let managed = root.appendingPathComponent("workspaces")
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: managed)
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        do {
            _ = try await service.create(WorkspaceCreateRequest(project: project, name: "Review"))
            XCTFail("Expected switch failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("connection lost"))
            XCTAssertTrue(error.localizedDescription.contains(managed.path + "/Game/Review"))
            XCTAssertTrue(error.localizedDescription.contains("br:/main/release/Review@game@team@cloud"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path + "/Game/Review/.plastic"))
        let mutations = await runner.mutations
        XCTAssertEqual(mutations.count, 3, "No automatic delete of the branch or workspace")
    }

    func testNewBranchStartsFromSelectedBaseBranchHead() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path)
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: root.appendingPathComponent("workspaces"))
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        let result = try await service.create(WorkspaceCreateRequest(
            project: project, name: "Review", branchMode: .new, baseBranch: "/main/other"))
        XCTAssertEqual(result.workspace.branch, "/main/other/Review")
        let mutations = await runner.mutations
        // Taban dalın ucu (cs:99) sorulmuş ve yeni dal ondan çıkmış olmalı.
        XCTAssertEqual(mutations[0].args[3], "--changeset=cs:99@game@team@cloud")
        let queries = await runner.findQueries
        XCTAssertEqual(queries.first, "changesets where branch = 'br:/main/other' order by changesetid desc limit 1")
    }

    func testSwitchesToSelectedExistingBranchWithoutCreatingIt() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path)
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: root.appendingPathComponent("workspaces"))
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        let result = try await service.create(WorkspaceCreateRequest(
            project: project, name: "Review", branchName: "/main/other", branchMode: .existing))
        XCTAssertEqual(result.workspace.branch, "/main/other")
        let mutations = await runner.mutations
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(mutations[1].args.first, "switch")
        XCTAssertEqual(mutations[1].args[1], "br:/main/other@game@team@cloud")
    }

    func testTypedBranchNameIsAppendedToTheBaseBranch() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path)
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: root.appendingPathComponent("workspaces"))
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        let result = try await service.create(WorkspaceCreateRequest(
            project: project, name: "Review", branchName: "my-feature", branchMode: .new, baseBranch: "/main/other"))
        XCTAssertEqual(result.workspace.branch, "/main/other/my-feature")
    }

    /// Plastic'te ara dallar kendiliğinden oluşmaz; hiyerarşi taban daldan gelir.
    func testSlashInPlasticBranchNameIsRejectedBeforeAnyCommand() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path)
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: root.appendingPathComponent("workspaces"))
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        do {
            _ = try await service.create(WorkspaceCreateRequest(
                project: project, name: "Review", branchName: "xxx/yyy/zzz", branchMode: .new))
            XCTFail("Çok parçalı dal adı reddedilmeli")
        } catch {
            let mutations = await runner.mutations
            XCTAssertTrue(mutations.isEmpty)
        }
    }

    func testListsPlasticBranchesAndServesRepeatCallsFromCache() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path)
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: root.appendingPathComponent("workspaces"))
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        let first = try await service.branches(project: project, limit: 3)
        let second = try await service.branches(project: project, limit: 3)
        XCTAssertEqual(first.map(\.name), ["/main", "/main/release", "/main/other"])
        XCTAssertEqual(second, first)
        let queries = await runner.findQueries
        XCTAssertEqual(queries, ["branches order by date desc limit 3"])
    }

    func testRejectsQuoteInBranchPathBeforeAnyCommand() async throws {
        let runner = PlasticCreationRunner(source: root.appendingPathComponent("source").path)
        let service = WorkspaceService(runner: runner, locator: FakeBinaryLocator(paths: ["cm": "/fake/cm"]), workspaceRoot: root.appendingPathComponent("workspaces"))
        let project = Repo(name: "Game", path: root.appendingPathComponent("source").path, isGitRepo: false, source: .standalone)
        do {
            _ = try await service.create(WorkspaceCreateRequest(
                project: project, name: "Review", branchMode: .new, baseBranch: "/main' or 1=1"))
            XCTFail("Tırnaklı dal adı reddedilmeli")
        } catch {
            let mutations = await runner.mutations
            XCTAssertTrue(mutations.isEmpty)
        }
    }

    func testParsesRealCLIHeaderAndRejectsAmbiguousSelectors() throws {
        let parsed = try PlasticWorkspaceMetadata(header: "STATUS|2588|word-puzzle|uncosoft@cloud\n", selector: "smartbranch \"/main/sand-blocks/release\" changeset \"2588\"")
        XCTAssertEqual(parsed.revision, "2588")
        XCTAssertEqual(parsed.branch, "/main/sand-blocks/release")
        XCTAssertEqual(parsed.repository, "word-puzzle@uncosoft@cloud")
        XCTAssertThrowsError(try PlasticWorkspaceMetadata(header: "STATUS|42|game|cloud", selector: "branch \"/main\"\nbranch \"/other\""))
        XCTAssertThrowsError(try PlasticWorkspaceMetadata(header: "unrecognized", selector: ""))
    }
}

private actor PlasticCreationRunner: ProcessRunning {
    struct Call: Sendable { let args: [String]; let cwd: String? }
    let source: String
    let failSwitch: Bool
    private(set) var mutations: [Call] = []
    private(set) var findQueries: [String] = []
    init(source: String, failSwitch: Bool = false) { self.source = source; self.failSwitch = failSwitch }
    func run(_ executable: String, arguments: [String], currentDirectory: String?, standardInput: Data?, timeout: TimeInterval) async -> ProcessOutput? {
        if executable == "/usr/bin/git" { return ProcessOutput(exitCode: 1, stdout: "", stderr: "not Git") }
        switch arguments.first {
        case "getworkspacefrompath": return ProcessOutput(exitCode: 0, stdout: "\(source)\tregular\tstatic", stderr: "")
        case "status": return ProcessOutput(exitCode: 0, stdout: "STATUS|42|game|team@cloud", stderr: "")
        case "find":
            findQueries.append(arguments.count > 1 ? arguments[1] : "")
            let isBranchList = arguments.dropFirst().first?.hasPrefix("branches") == true
            return ProcessOutput(exitCode: 0, stdout: isBranchList ? "/main\n/main/release\n/main/other" : "99", stderr: "")
        case "branch", "workspace", "switch":
            mutations.append(Call(args: arguments, cwd: currentDirectory))
            if arguments.first == "workspace", arguments.count >= 4 {
                do { try FileManager.default.createDirectory(atPath: arguments[3] + "/.plastic", withIntermediateDirectories: true) }
                catch { return ProcessOutput(exitCode: 1, stdout: "", stderr: error.localizedDescription) }
            }
            if arguments.first == "switch", failSwitch { return ProcessOutput(exitCode: 1, stdout: "", stderr: "connection lost") }
            return ProcessOutput(exitCode: 0, stdout: "", stderr: "")
        default: return ProcessOutput(exitCode: 1, stdout: "", stderr: "Unexpected command")
        }
    }
    func runRaw(_ executable: String, arguments: [String], currentDirectory: String?, standardInput: Data?, timeout: TimeInterval) async -> RawProcessOutput? { nil }
}
