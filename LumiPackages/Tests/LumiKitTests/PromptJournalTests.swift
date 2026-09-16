import Testing
import Foundation
@testable import LumiKit

@Suite struct PromptJournalTests {
    private let term = TerminalID()
    private func ev(_ kind: AgentHookEventKind, tool: String? = nil, input: String? = nil,
                    useID: String? = nil, source: String? = nil, agentID: String? = nil) -> AgentHookEvent {
        AgentHookEvent(provider: .claude, terminalID: term, kind: kind, agentID: agentID,
                       teammateName: nil, toolName: tool, source: source, trigger: nil,
                       isInterrupt: false, promptHead: nil, runningBackgroundAgentIDs: nil,
                       toolInput: input, toolUseID: useID)
    }
    private func journal() -> PromptJournal { var n = 0; return PromptJournal(seq: { n += 1; return n }) }

    @Test func askUserQuestionBecomesQuestionItem() {
        let j = journal()
        let input = #"{"questions":[{"question":"Pick DB","options":[{"label":"PG","description":"rel"},{"label":"Mongo"}]}]}"#
        let changed = j.reduce(ev(.preToolUse, tool: "AskUserQuestion", input: input, useID: "tu1"))
        #expect(changed.count == 1)
        let p = changed[0]
        #expect(p.kind == .question)
        #expect(p.itemId == "tu1")
        #expect(p.title == "Pick DB")
        #expect(p.options.map(\.label) == ["PG", "Mongo"])
        #expect(p.options[0].id == "opt-0")
        #expect(p.state == .pending)
    }

    @Test func permissionBecomesApprovalItem() {
        let j = journal()
        let changed = j.reduce(ev(.permissionRequest, tool: "Bash", input: #"{"command":"npm i"}"#, useID: "tu2"))
        #expect(changed.count == 1)
        #expect(changed[0].kind == .approval)
        #expect(changed[0].options.map(\.id) == ["allow", "deny"])
    }

    @Test func postToolCancelsPending() {
        let j = journal()
        _ = j.reduce(ev(.permissionRequest, tool: "Bash", input: "{}", useID: "tu3"))
        let changed = j.reduce(ev(.postToolUse, tool: "Bash", useID: "tu3"))
        #expect(changed.first?.state == .cancelled)
    }

    @Test func stopCancelsAllPending() {
        let j = journal()
        _ = j.reduce(ev(.permissionRequest, tool: "Bash", input: "{}", useID: "tu4"))
        let changed = j.reduce(ev(.stop))
        #expect(changed.allSatisfy { $0.state == .cancelled })
        #expect(!changed.isEmpty)
    }

    @Test func subagentAndUnrelatedIgnored() {
        let j = journal()
        #expect(j.reduce(ev(.preToolUse, tool: "AskUserQuestion", input: "{}", agentID: "sub")).isEmpty)
        #expect(j.reduce(ev(.preToolUse, tool: "Bash", input: "{}")).isEmpty)
    }

    @Test func clearResetsJournalAndCancelsPending() {
        let j = journal()
        _ = j.reduce(ev(.permissionRequest, tool: "Bash", input: "{}", useID: "tu5"))
        let changed = j.reduce(ev(.sessionStart, source: "clear"))
        #expect(j.items.isEmpty)
        // pending item cancelled olarak yayınlanır (telefon kartı düşsün)
        #expect(changed.count == 1)
        #expect(changed.first?.state == .cancelled)
        #expect(changed.first?.itemId == "tu5")
    }

    @Test func resolveMarksResolvedAndBumpsRevision() {
        let j = journal()
        _ = j.reduce(ev(.permissionRequest, tool: "Bash", input: "{}", useID: "tu6"))
        let resolved = j.resolve(itemId: "tu6", optionId: "allow")
        #expect(resolved?.state == .resolved)
        #expect(resolved?.selectedOptionId == "allow")
        #expect(resolved?.revision == 1)
        #expect(j.items.first { $0.itemId == "tu6" }?.state == .resolved)
    }

    @Test func stopFromSubagentDoesNotCancel() {
        let j = journal()
        _ = j.reduce(ev(.permissionRequest, tool: "Bash", input: "{}", useID: "tu7"))
        #expect(j.reduce(ev(.stop, agentID: "sub")).isEmpty)  // isLead=false → dokunmaz
        #expect(j.items.first { $0.itemId == "tu7" }?.state == .pending)
    }

    @Test func singleQuestionMultiSelectFlag() {
        let j = journal()
        let input = #"{"questions":[{"question":"Pick","multiSelect":true,"options":[{"label":"A"},{"label":"B"}]}]}"#
        let changed = j.reduce(ev(.preToolUse, tool: "AskUserQuestion", input: input, useID: "m1"))
        #expect(changed.first?.multiSelect == true)
        #expect(changed.first?.questions.isEmpty == true)   // tek soru → flat
    }

    @Test func groupedMultiQuestionPopulatesQuestions() {
        let j = journal()
        let input = #"{"questions":[{"question":"Q0","header":"H0","options":[{"label":"A"}]},{"question":"Q1","multiSelect":true,"options":[{"label":"C"},{"label":"D"}]}]}"#
        let changed = j.reduce(ev(.preToolUse, tool: "AskUserQuestion", input: input, useID: "g1"))
        #expect(changed.first?.questions.count == 2)
        #expect(changed.first?.questions.first?.header == "H0")
        #expect(changed.first?.questions.last?.multiSelect == true)
        #expect(changed.first?.options.isEmpty == true)   // gruplu → flat options boş
    }

    @Test func questionWithoutOptionsNotCreated() {
        let j = journal()
        let changed = j.reduce(ev(.preToolUse, tool: "AskUserQuestion",
                                   input: #"{"questions":[{"question":"Q"}]}"#, useID: "tu8"))
        #expect(changed.isEmpty)   // options yok → item yaratılmaz
        #expect(j.items.isEmpty)
    }
}
