import Foundation
import XCTest
@testable import CallVoice

private actor VoiceWireRecorder {
    var messages: [Data] = []
    var calls: [String] = []
    var audio: [Data] = []
    func sent(_ data: Data) { messages.append(data) }
    func called(_ id: String) { calls.append(id) }
    func heard(_ data: Data) { audio.append(data) }
}
private actor VoiceAnswerGate {
    var continuations: [CheckedContinuation<String, Never>] = []
    func wait(registered: @Sendable () -> Void = {}) async -> String {
        await withCheckedContinuation { continuations.append($0); registered() }
    }
    func answer(_ value: String) {
        let waiting = continuations; continuations.removeAll()
        for continuation in waiting { continuation.resume(returning: value) }
    }
}

final class LiveDelegationTests: XCTestCase {
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func wrapper(_ event: [String: Any], delegation: String? = "delegation_1") throws -> Data {
        try data(["type": "response.event", "delegation_id": delegation.map { $0 as Any } ?? NSNull(), "event": event])
    }
    private func call(_ id: String = "call_1", name: String = "ask_codex", arguments: String = "{\"question\":\"What time?\"}") -> LiveDelegationCall {
        .init(name: name, arguments: arguments, callID: id)
    }
    private func tool(_ call: LiveDelegationCall) -> [String: Any] {
        ["type": "response.output_item.done", "output_index": 0, "sequence_number": 2,
         "item": ["type": "function_call", "id": "item_" + call.callID, "call_id": call.callID,
                  "name": call.name, "arguments": call.arguments, "status": "completed"]]
    }
    private func boundary(_ type: String, _ id: String = "response_1") -> [String: Any] {
        ["type": type, "sequence_number": type == "response.created" ? 0 : 3,
         "response": ["id": id, "output": []]]
    }
    private func deliverBatch(_ session: LiveVoiceSession, calls: [LiveDelegationCall],
                              response: String = "response_1", delegation: String = "delegation_1") async throws {
        await session.handleServerEvent(try wrapper(boundary("response.created", response), delegation: delegation))
        for call in calls { await session.handleServerEvent(try wrapper(tool(call), delegation: delegation)) }
        await session.handleServerEvent(try wrapper(boundary("response.completed", response), delegation: delegation))
    }
    private func objects(_ messages: [Data]) throws -> [[String: Any]] {
        try messages.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }

    func testDelegationToolsAreOptInAndHaveOnlyNarrowArguments() throws {
        func responses(_ enabled: Bool) throws -> [String: Any] {
            let start = LiveProtocol.start(instructions: "Call task", context: "", delegationEnabled: enabled)
            let session = try XCTUnwrap(start["session"] as? [String: Any])
            let delegation = try XCTUnwrap(session["delegation"] as? [String: Any])
            return try XCTUnwrap(delegation["responses"] as? [String: Any])
        }
        XCTAssertNil(try responses(false)["tools"])
        let enabled = try responses(true)
        XCTAssertEqual(enabled["parallel_tool_calls"] as? Bool, false)
        let tools = try XCTUnwrap(enabled["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["ask_codex", "report_call_result"])
        for (tool, field) in zip(tools, ["question", "summary"]) {
            XCTAssertEqual(tool["type"] as? String, "function")
            XCTAssertEqual(tool["strict"] as? Bool, true)
            XCTAssertNil(tool["function"])
            let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertEqual(schema["required"] as? [String], [field])
            XCTAssertEqual((schema["properties"] as? [String: Any])?.keys.sorted(), [field])
        }
    }

    func testSDKEnvelopeDecodesGranularToolItemsAndResponseBoundaries() throws {
        XCTAssertEqual(try LiveProtocol.decode(wrapper(boundary("response.created"))),
                       .delegation(.started(delegationID: "delegation_1", responseID: "response_1")))
        // The SDK granular item has no response_id. The nested item ID is not
        // the function call_id used when sending the result.
        XCTAssertEqual(try LiveProtocol.decode(wrapper(tool(call()))),
                       .delegation(.toolCompleted(delegationID: "delegation_1", call: call())))
        XCTAssertEqual(try LiveProtocol.decode(wrapper(boundary("response.completed"), delegation: nil)),
                       .delegation(.completed(delegationID: nil, responseID: "response_1")))
        for kind in ["response.failed", "response.incomplete"] {
            XCTAssertEqual(try LiveProtocol.decode(wrapper(boundary(kind))),
                           .delegation(.abandoned(delegationID: "delegation_1", responseID: "response_1")))
        }
        XCTAssertEqual(try LiveProtocol.decode(wrapper(["type": "response.function_call_arguments.delta", "delta": "partial"])), .ignored)
        XCTAssertThrowsError(try LiveProtocol.decode(wrapper(["type": "response.completed", "response": [:]])))
        var invalid = tool(call()); invalid["item"] = ["type": "function_call", "id": "not-call-id", "name": "ask_codex", "arguments": "{}"]
        XCTAssertThrowsError(try LiveProtocol.decode(wrapper(invalid)))
    }

    func testDuplicatesWaitForMatchingCompletionAndExecuteOnlyOnceAcrossResponses() throws {
        var state = LiveDelegationState()
        XCTAssertNil(try state.accept(.toolCompleted(delegationID: nil, call: call())))
        XCTAssertNil(try state.accept(.started(delegationID: nil, responseID: "r1")))
        XCTAssertNil(try state.accept(.toolCompleted(delegationID: nil, call: call())))
        // A duplicated created event must not erase collected tool calls.
        XCTAssertNil(try state.accept(.started(delegationID: nil, responseID: "r1")))
        XCTAssertNil(try state.accept(.toolCompleted(delegationID: nil, call: call())))
        XCTAssertNil(try state.accept(.completed(delegationID: nil, responseID: "stale")))
        XCTAssertEqual(try state.accept(.completed(delegationID: nil, responseID: "r1"))?.calls, [call()])
        XCTAssertNil(try state.accept(.completed(delegationID: nil, responseID: "r1")))
        _ = try state.accept(.started(delegationID: nil, responseID: "r2"))
        _ = try state.accept(.toolCompleted(delegationID: nil, call: call()))
        XCTAssertNil(try state.accept(.completed(delegationID: nil, responseID: "r2")))
        _ = try state.accept(.started(delegationID: nil, responseID: "r3"))
        XCTAssertThrowsError(try state.accept(.toolCompleted(delegationID: nil,
            call: call(arguments: "{\"question\":\"Different question\"}"))))
    }

    func testResponseReplacementFailureAndCrossDelegationDeduplication() throws {
        var state = LiveDelegationState()
        _ = try state.accept(.started(delegationID: "d1", responseID: "old"))
        _ = try state.accept(.toolCompleted(delegationID: "d1", call: call("discarded")))
        _ = try state.accept(.started(delegationID: "d1", responseID: "new"))
        _ = try state.accept(.toolCompleted(delegationID: "d1", call: call("shared")))
        _ = try state.accept(.started(delegationID: "d2", responseID: "other"))
        _ = try state.accept(.toolCompleted(delegationID: "d2", call: call("shared")))
        XCTAssertNil(try state.accept(.completed(delegationID: "d1", responseID: "old")))
        XCTAssertEqual(try state.accept(.completed(delegationID: "d1", responseID: "new"))?.calls, [call("shared")])
        XCTAssertNil(try state.accept(.completed(delegationID: "d2", responseID: "other")))
        _ = try state.accept(.started(delegationID: nil, responseID: "failure"))
        _ = try state.accept(.toolCompleted(delegationID: nil, call: call("never")))
        _ = try state.accept(.abandoned(delegationID: nil, responseID: "failure"))
        XCTAssertNil(try state.accept(.completed(delegationID: nil, responseID: "failure")))
        state.close()
        XCTAssertNil(try state.accept(.started(delegationID: nil, responseID: "after-close")))
        XCTAssertNil(try state.accept(.toolCompleted(delegationID: nil, call: call())))
        XCTAssertNil(try state.accept(.completed(delegationID: nil, responseID: "after-close")))
    }

    func testMissingCorrelationResolvesOnlyUnambiguousResponses() throws {
        var state = LiveDelegationState()
        _ = try state.accept(.started(delegationID: "d1", responseID: "r1"))
        _ = try state.accept(.toolCompleted(delegationID: nil, call: call("one")))
        XCTAssertEqual(try state.accept(.completed(delegationID: nil, responseID: "r1"))?.calls, [call("one")])
        _ = try state.accept(.started(delegationID: nil, responseID: "r2"))
        _ = try state.accept(.toolCompleted(delegationID: "late-correlation", call: call("two")))
        XCTAssertEqual(try state.accept(.completed(delegationID: "late-correlation", responseID: "r2"))?.calls, [call("two")])
        _ = try state.accept(.started(delegationID: "d3", responseID: "r3"))
        _ = try state.accept(.started(delegationID: "d4", responseID: "r4"))
        _ = try state.accept(.toolCompleted(delegationID: nil, call: call("ambiguous")))
        _ = try state.accept(.toolCompleted(delegationID: "d4", call: call("four")))
        XCTAssertNil(try state.accept(.completed(delegationID: nil, responseID: "r3")))
        XCTAssertEqual(try state.accept(.completed(delegationID: nil, responseID: "r4"))?.calls, [call("four")])
    }

    func testInstructionsKeepLongCodexAnswerWholeAndRejectOversizeInsteadOfTruncating() throws {
        let answer = "Answer from the originating Codex task: " + String(repeating: "a", count: 8000)
        XCTAssertEqual(try LiveProtocol.instructions(answer)["content"] as? String, answer)
        XCTAssertEqual(try LiveProtocol.instructions(String(repeating: "x", count: 12000))["content"] as? String,
                       String(repeating: "x", count: 12000))
        XCTAssertThrowsError(try LiveProtocol.instructions(String(repeating: "x", count: 12001)))
    }

    func testArgumentValidationDoesNotAcceptDestinationsOrBroadTools() throws {
        XCTAssertEqual(try LiveProtocol.checkedToolArguments(call()), call().arguments)
        XCTAssertNoThrow(try LiveProtocol.checkedToolArguments(call(name: "report_call_result", arguments: "{\"summary\":\"Appointment confirmed\"}")))
        for invalid in [call(name: "shell"), call(arguments: "{\"question\":\"x\",\"thread_id\":\"other\"}"),
                        call(arguments: "{\"question\":\"  \"}"), call(arguments: "{\"question\":true}"),
                        call(arguments: "{\"question\":\"" + String(repeating: "x", count: 4001) + "\"}")] {
            XCTAssertThrowsError(try LiveProtocol.checkedToolArguments(invalid))
        }
    }

    func testAwaitingQuestionDoesNotBlockAudioAndContinuesOnceWithLaterInstructions() async throws {
        let wire = VoiceWireRecorder(), answer = VoiceAnswerGate()
        let asked = expectation(description: "asked originating task")
        let continued = expectation(description: "one response continuation")
        let session = LiveVoiceSession(audio: { await wire.heard($0) }, delegation: { name, arguments, id in
            XCTAssertEqual(name, "ask_codex"); XCTAssertTrue(arguments.contains("question"))
            await wire.called(id)
            return await answer.wait { asked.fulfill() }
        }, sendEvent: { data in
            await wire.sent(data)
            if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String == "response.create" { continued.fulfill() }
        })
        await session.handleServerEvent(try data(["type": "session.started"]))
        try await deliverBatch(session, calls: [call(), call()])
        await fulfillment(of: [asked], timeout: 1)
        let pcm = Data([0, 1, 0, 2])
        await session.handleServerEvent(try data(["type": "session.output_audio.delta", "delta": pcm.base64EncodedString()]))
        let heard = await wire.audio
        XCTAssertEqual(heard, [pcm])
        await answer.answer("{\"status\":\"awaiting_codex\"}")
        await fulfillment(of: [continued], timeout: 1)
        try await session.instruct("Answer from the originating Codex task: after 3 PM.")
        let messages = try objects(await wire.messages)
        XCTAssertEqual(messages.compactMap { $0["type"] as? String }, ["response.item.create", "response.create", "session.instructions.append"])
        let item = try XCTUnwrap(messages[0]["item"] as? [String: Any])
        XCTAssertEqual(item["call_id"] as? String, "call_1")
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["output"] as? String, "{\"status\":\"awaiting_codex\"}")
        XCTAssertNil(messages[0]["delegation_id"])
        XCTAssertTrue(messages[2]["delegation_id"] is NSNull)
        await session.close()
    }

    func testCloseDiscardsAnUncooperativeLateToolAnswer() async throws {
        let gate = VoiceAnswerGate()
        let asked = expectation(description: "handler started")
        let lateSend = expectation(description: "no sends from retired session"); lateSend.isInverted = true
        let returned = expectation(description: "handler returned after close")
        let session = LiveVoiceSession(audio: { _ in XCTFail("Retired audio") }, delegation: { _, _, _ in
            let result = await gate.wait { asked.fulfill() }; returned.fulfill(); return result
        }, sendEvent: { _ in lateSend.fulfill() })
        await session.handleServerEvent(try data(["type": "session.started"]))
        try await deliverBatch(session, calls: [call()])
        await fulfillment(of: [asked], timeout: 1)
        await session.close()
        await gate.answer("late private fact")
        await fulfillment(of: [returned], timeout: 1)
        await session.handleServerEvent(try wrapper(boundary("response.completed")))
        await fulfillment(of: [lateSend], timeout: 0.05)
        do { try await session.instruct("late answer"); XCTFail("Closed session accepted instructions") } catch {}
    }

    func testInvalidToolProducesOneBoundedResultWithoutInvokingHandler() async throws {
        let wire = VoiceWireRecorder()
        let continued = expectation(description: "invalid tool continuation")
        let session = LiveVoiceSession(audio: { _ in }, delegation: { _, _, _ in
            XCTFail("Unexpected external tool invocation"); return "bad"
        }, sendEvent: { data in
            await wire.sent(data)
            if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String == "response.create" { continued.fulfill() }
        })
        await session.handleServerEvent(try data(["type": "session.started"]))
        try await deliverBatch(session, calls: [call(name: "shell")])
        await fulfillment(of: [continued], timeout: 1)
        let messages = try objects(await wire.messages)
        XCTAssertEqual(messages.count, 2)
        let item = try XCTUnwrap(messages[0]["item"] as? [String: Any])
        XCTAssertTrue((item["output"] as? String)?.contains("Unsupported voice delegation tool") == true)
        await session.close()
    }

    func testBatchRepliesUseCallIDsAndContinueOnlyAfterEveryResult() async throws {
        let wire = VoiceWireRecorder()
        let continued = expectation(description: "batch continued once")
        let session = LiveVoiceSession(audio: { _ in }, delegation: { name, _, id in
            await wire.called(id)
            if name == "ask_codex" { throw LiveVoiceError("Unavailable sk-do-not-expose") }
            return "{\"recorded\":true,\"phoneHangupConfirmed\":false}"
        }, sendEvent: { data in
            await wire.sent(data)
            if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String == "response.create" { continued.fulfill() }
        })
        await session.handleServerEvent(try data(["type": "session.started"]))
        try await deliverBatch(session, calls: [call("ask"), call("report", name: "report_call_result", arguments: "{\"summary\":\"Confirmed\"}")])
        await fulfillment(of: [continued], timeout: 1)
        let messages = try objects(await wire.messages)
        XCTAssertEqual(messages.compactMap { $0["type"] as? String }, ["response.item.create", "response.item.create", "response.create"])
        let items = messages.compactMap { $0["item"] as? [String: Any] }
        XCTAssertEqual(items.compactMap { $0["call_id"] as? String }, ["ask", "report"])
        XCTAssertTrue((items[0]["output"] as? String)?.contains("[redacted]") == true)
        XCTAssertFalse((items[0]["output"] as? String)?.contains("sk-do") == true)
        let called = await wire.calls
        XCTAssertEqual(called, ["ask", "report"])
        await session.close()
    }

    func testUnconfiguredSessionIgnoresDelegationAndKeepsNormalVoiceInput() async throws {
        let wire = VoiceWireRecorder()
        let session = LiveVoiceSession(audio: { _ in }, failure: { _ in XCTFail("Legacy no-tools session should ignore response events") },
                                       sendEvent: { await wire.sent($0) })
        await session.handleServerEvent(try data(["type": "session.started"]))
        await session.handleServerEvent(try data(["type": "response.event"]))
        try await deliverBatch(session, calls: [call()])
        try await session.sendInput("AAA=")
        let messages = try objects(await wire.messages)
        XCTAssertEqual(messages.compactMap { $0["type"] as? String }, ["session.input_audio.append"])
        await session.close()
    }

    func testOutstandingDelegationsAreCappedAndCancelledOnFailure() async throws {
        let gate = VoiceAnswerGate()
        let started = expectation(description: "four pending handlers"); started.expectedFulfillmentCount = 4
        let failed = expectation(description: "bounded outstanding delegates")
        let returned = expectation(description: "pending handlers retire"); returned.expectedFulfillmentCount = 4
        let forbiddenSend = expectation(description: "cancelled results discarded"); forbiddenSend.isInverted = true
        let session = LiveVoiceSession(audio: { _ in }, failure: { message in
            XCTAssertTrue(message.contains("Too many voice delegations")); failed.fulfill()
        }, delegation: { _, _, _ in
            let result = await gate.wait { started.fulfill() }; returned.fulfill(); return result
        }, sendEvent: { _ in forbiddenSend.fulfill() })
        await session.handleServerEvent(try data(["type": "session.started"]))
        for index in 0..<4 {
            try await deliverBatch(session, calls: [call("call_\(index)")], response: "r\(index)", delegation: "d\(index)")
        }
        await fulfillment(of: [started], timeout: 1)
        try await deliverBatch(session, calls: [call("fifth")], response: "r5", delegation: "d5")
        await fulfillment(of: [failed], timeout: 1)
        await gate.answer("late")
        await fulfillment(of: [returned], timeout: 1)
        await fulfillment(of: [forbiddenSend], timeout: 0.05)
        await session.close()
    }
}
