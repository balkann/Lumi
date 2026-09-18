import Testing
import Foundation
@testable import LumiMobileKit

@Suite struct BranchWorktreeWireTests {
    @Test func startSessionEncodesWorkspaceFields() throws {
        let cmd = OutgoingCommand(commandId: "c1", action: .startSession(
            repoPath: "/tmp/r", personaId: nil, prompt: "hi", kind: "chat",
            branchMode: "new", branchName: "feat", baseBranch: "main", workspaceName: "ws1"))
        let text = PhoneProtocol.commandFrame(cmd)
        let obj = try JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! [String: Any]
        let payload = obj["payload"] as! [String: Any]
        #expect(payload["action"] as? String == "start_session")
        #expect(payload["branchMode"] as? String == "new")
        #expect(payload["branchName"] as? String == "feat")
        #expect(payload["baseBranch"] as? String == "main")
        #expect(payload["workspaceName"] as? String == "ws1")
    }

    @Test func listBranchesEncodes() throws {
        let cmd = OutgoingCommand(commandId: "c2", action: .listBranches(repoPath: "/tmp/r"))
        let text = PhoneProtocol.commandFrame(cmd)
        let obj = try JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! [String: Any]
        let payload = obj["payload"] as! [String: Any]
        #expect(payload["action"] as? String == "list_branches")
        #expect(payload["repoPath"] as? String == "/tmp/r")
    }

    @Test func commandResultDecodesBranches() throws {
        let json = #"{"v":1,"type":"command_result","payload":{"commandId":"c2","ok":true,"branches":["main","dev"]}}"#
        let msg = PhoneProtocol.decodeServerMessage(json)
        guard case .commandResult(let r) = msg else { Issue.record("beklenen commandResult"); return }
        #expect(r.branches == ["main", "dev"])
    }
}
