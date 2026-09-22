import Testing
import Foundation
@testable import LumiKit

@Suite struct ChatPromptTests {
    @Test func toDictEncodesOptionsAndState() {
        let p = ChatPrompt(itemId: "i1", revision: 2, kind: .question, title: "Pick",
            detail: nil, options: [ChatPromptOption(id: "opt-0", label: "A", description: "aa")],
            state: .pending, selectedOptionId: nil)
        let d = p.toDict()
        #expect(d["itemId"] as? String == "i1")
        #expect(d["revision"] as? Int == 2)
        #expect(d["kind"] as? String == "question")
        #expect(d["state"] as? String == "pending")
        #expect(d["selectedOptionId"] is NSNull)
        let opts = d["options"] as? [[String: Any]]
        #expect(opts?.first?["id"] as? String == "opt-0")
        #expect(opts?.first?["label"] as? String == "A")
        #expect(opts?.first?["description"] as? String == "aa")
    }

    @Test func toDictEncodesFaz31Fields() {
        let p = ChatPrompt(itemId: "i1", revision: 0, kind: .question, title: "G", detail: nil,
            options: [], state: .pending, selectedOptionId: nil, multiSelect: true, allowOther: true,
            questions: [ChatPromptQuestion(id: "q0", question: "Q0", header: "H", multiSelect: false,
                                           allowOther: false, options: [ChatPromptOption(id: "opt-0", label: "A", description: nil)])])
        let d = p.toDict()
        #expect(d["multiSelect"] as? Bool == true)
        #expect(d["allowOther"] as? Bool == true)
        let qs = d["questions"] as? [[String: Any]]
        #expect(qs?.first?["id"] as? String == "q0")
        #expect(qs?.first?["header"] as? String == "H")
        #expect((qs?.first?["options"] as? [[String: Any]])?.first?["label"] as? String == "A")
    }
}
