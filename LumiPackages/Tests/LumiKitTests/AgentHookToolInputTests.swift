import Testing
import Foundation
@testable import LumiKit

@Suite struct AgentHookToolInputTests {
    private func parse(_ json: String) -> AgentHookEvent? {
        AgentHookEvent.parse(provider: .claude, terminalID: TerminalID(),
                             body: Data(json.utf8), receivedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func extractsToolInputObjectAsString() {
        let e = parse(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"q"}]},"tool_use_id":"tu_1"}"#)
        #expect(e?.toolName == "AskUserQuestion")
        #expect(e?.toolUseID == "tu_1")
        // toolInput geçerli JSON string olmalı ve "questions" içermeli
        let data = e?.toolInput.flatMap { $0.data(using: .utf8) }
        let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(obj?["questions"] != nil)
    }

    @Test func nilToolInputWhenAbsent() {
        let e = parse(#"{"hook_event_name":"Stop"}"#)
        #expect(e?.toolInput == nil)
        #expect(e?.toolUseID == nil)
    }

    @Test func nilWhenToolInputExceedsCap() {
        let big = String(repeating: "x", count: 20_000)
        let e = parse(#"{"hook_event_name":"PreToolUse","tool_input":{"blob":"\#(big)"}}"#)
        #expect(e?.toolInput == nil)   // 16 KB tavan aşıldı
    }
}
