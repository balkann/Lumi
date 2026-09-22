import Testing
import LumiWire
@testable import LumiRemote

/// Regression guard: Mac-encode (RemoteProtocol.*Payload) → shared LumiWire decode
/// round-trips without data loss or key collision.
///
/// Architecture note: all three toDict() implementations live in LumiWire itself;
/// RemoteProtocol.*Payload functions inject `sessionId` into the dict and nothing else.
/// These tests confirm that sessionId injection does not shadow any model field, and
/// that the full field set survives encode→decode with equality.
@Suite struct WireRoundTripTests {

    // MARK: - ChatPrompt

    @Test func promptPayloadRoundTripsThroughLumiWireDecode() {
        let option = ChatPromptOption(id: "opt-0", label: "Allow", description: "Grants access")
        let question = ChatPromptQuestion(
            id: "q0", question: "Which scope?", header: "Scope",
            multiSelect: true, allowOther: false,
            options: [ChatPromptOption(id: "opt-0", label: "Read", description: nil)]
        )
        let original = ChatPrompt(
            itemId: "i1", revision: 3, kind: .question, title: "Pick a scope",
            detail: "Details here", options: [option], state: .pending,
            selectedOptionId: nil, multiSelect: true, allowOther: true,
            questions: [question]
        )

        // Mac encode: adds sessionId key on top of prompt.toDict()
        let payload = RemoteProtocol.promptPayload(sessionId: "sess-abc", prompt: original)

        // sessionId must be present in payload (sanity)
        #expect(payload["sessionId"] as? String == "sess-abc")

        // LumiWire decode must ignore sessionId and recover the full model
        let decoded = ChatPrompt.decode(payload)
        #expect(decoded == original)
    }

    @Test func promptPayloadApprovalKindRoundTrips() {
        let original = ChatPrompt(
            itemId: "i2", revision: 1, kind: .approval, title: "Allow bash?",
            detail: nil, options: [ChatPromptOption(id: "opt-0", label: "Yes", description: nil)],
            state: .pending, selectedOptionId: nil, multiSelect: false, allowOther: false,
            questions: []
        )

        let payload = RemoteProtocol.promptPayload(sessionId: "s1", prompt: original)
        let decoded = ChatPrompt.decode(payload)
        #expect(decoded == original)
    }

    @Test func promptPayloadResolvedStateRoundTrips() {
        let original = ChatPrompt(
            itemId: "i3", revision: 2, kind: .approval, title: "Done",
            detail: nil, options: [ChatPromptOption(id: "opt-0", label: "Yes", description: nil)],
            state: .resolved, selectedOptionId: "opt-0",
            multiSelect: false, allowOther: false, questions: []
        )

        let payload = RemoteProtocol.promptPayload(sessionId: "s2", prompt: original)
        let decoded = ChatPrompt.decode(payload)
        #expect(decoded == original)
    }

    // MARK: - ChatTurnStatus

    @Test func chatStatusPayloadRoundTripsThroughLumiWireDecode() {
        let original = ChatTurnStatus(working: true, startedAtMs: 1_700_000_000_000, tool: "bash")

        // Mac encode: adds sessionId into status.toDict()
        let payload = RemoteProtocol.chatStatusPayload(sessionId: "sess-xyz", status: original)

        #expect(payload["sessionId"] as? String == "sess-xyz")

        // ChatTurnStatus.decode ignores unknown keys including sessionId
        let decoded = ChatTurnStatus.decode(payload)
        #expect(decoded == original)
    }

    @Test func chatStatusPayloadIdleRoundTrips() {
        let original = ChatTurnStatus.idle

        let payload = RemoteProtocol.chatStatusPayload(sessionId: "s3", status: original)
        let decoded = ChatTurnStatus.decode(payload)
        #expect(decoded == original)
    }

    @Test func chatStatusStreamingTextRoundTrips() {
        let status = ChatTurnStatus(working: true, startedAtMs: 100, tool: "Bash", streamingText: "Sel")
        let payload = RemoteProtocol.chatStatusPayload(sessionId: "s1", status: status)
        let decoded = ChatTurnStatus.decode(payload)
        #expect(decoded.streamingText == "Sel")
        #expect(decoded.working == true)
    }

    // MARK: - ChatMessage (via chatPayload)

    /// chatPayload produces `{sessionId, messages:[msg.toDict()]}`.
    /// ChatMessage.decode is called on the inner dict (messages[0]), not the outer payload.
    /// This confirms RemoteProtocol.chatPayload doesn't corrupt the inner message dict.
    @Test func chatPayloadMessageRoundTripsThroughLumiWireDecode() {
        let original = ChatMessage(
            id: "msg-1", role: .assistant,
            blocks: [
                .text("Hello world", presentation: nil),
                .toolCall(name: "bash", inputPreview: "ls -la", state: "done"),
            ],
            timestampMs: 1_700_000_001_000,
            turnId: "turn-1"
        )

        let payload = RemoteProtocol.chatPayload(sessionId: "sess-msg", messages: [original])

        #expect(payload["sessionId"] as? String == "sess-msg")

        // Extract the inner message dict — this is what the iOS decoder receives
        guard let messagesArray = payload["messages"] as? [[String: Any]],
              let firstMsgDict = messagesArray.first else {
            Issue.record("messages array missing or empty in chatPayload")
            return
        }

        let decoded = ChatMessage.decode(firstMsgDict)
        #expect(decoded == original)
    }

    @Test func chatAppendPayloadMessageRoundTripsThroughLumiWireDecode() {
        let original = ChatMessage(
            id: "msg-2", role: .user,
            blocks: [.text("Hi", presentation: nil)],
            timestampMs: nil,
            turnId: nil
        )

        let payload = RemoteProtocol.chatAppendPayload(sessionId: "sess-append", messages: [original])

        guard let messagesArray = payload["messages"] as? [[String: Any]],
              let firstMsgDict = messagesArray.first else {
            Issue.record("messages array missing or empty in chatAppendPayload")
            return
        }

        let decoded = ChatMessage.decode(firstMsgDict)
        #expect(decoded == original)
    }
}
