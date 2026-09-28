import Foundation
import XCTest
@testable import CallControl

private final class ScriptedCodexTransport: CodexCallbackTransport, @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []
    private var stopped = false
    var handler: (([String: Any], ScriptedCodexTransport) -> Void)?
    init() {
        var saved: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream { saved = $0 }
        continuation = saved
    }
    var messages: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var wasClosed: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func start() throws {}
    func send(_ line: Data) throws {
        let object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        lock.lock()
        guard !stopped else { lock.unlock(); throw CodexCallbackError.closed }
        recorded.append(object)
        lock.unlock()
        handler?(object, self)
    }
    func emit(_ object: [String: Any]) {
        continuation.yield(try! JSONSerialization.data(withJSONObject: object))
    }
    func emitRaw(_ data: Data) { continuation.yield(data) }
    func disconnect() { continuation.finish(throwing: CodexCallbackError.disconnected(deliveryUncertain: false)) }
    func close() { lock.lock(); stopped = true; lock.unlock(); continuation.finish() }
    func respondNormally(_ object: [String: Any], turnID: String = "turn-test") {
        guard let id = object["id"] else { return }
        switch object["method"] as? String {
        case "initialize": emit(["id": id, "result": ["userAgent": "test", "codexHome": "/test", "platformFamily": "unix", "platformOs": "macos"]])
        case "thread/resume":
            let thread = (object["params"] as! [String: Any])["threadId"] as! String
            emit(["id": id, "result": ["thread": ["id": thread]]])
        case "turn/start": emit(["id": id, "result": ["turn": ["id": turnID, "status": "inProgress"]]])
        default: break
        }
    }
}

final class CodexCallbackTests: XCTestCase {
    func testEnvelopeCannotRetargetOriginAndPayloadIsJSONString() throws {
        let params = try CodexCallbackWire.parameters(threadID: "immutable-origin", name: "call_agent_question",
            payload: ["threadId": "untrusted-other-task", "question": "Does this work?", "number": 3])
        XCTAssertEqual(params["threadId"] as? String, "immutable-origin")
        XCTAssertEqual((params["input"] as? [Any])?.count, 0)
        let output = try XCTUnwrap(params["toolOutput"] as? [String: Any])
        XCTAssertEqual(output["name"] as? String, "call_agent_question")
        XCTAssertEqual(output["namespace"] as? String, "codex_call")
        let data = try XCTUnwrap((output["output"] as? String)?.data(using: .utf8))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["number"] as? Int, 3)
    }
    func testInvalidNamesIDsAndOversizedPayloadFailBeforeTransport() throws {
        for id in ["", " ", "origin\nother", String(repeating: "x", count: 161)] {
            XCTAssertThrowsError(try CodexCallbackWire.parameters(threadID: id, name: "call_agent_result", payload: [:]))
        }
        XCTAssertThrowsError(try CodexCallbackWire.parameters(threadID: "origin", name: "thread/start", payload: [:]))
        XCTAssertThrowsError(try CodexCallbackWire.parameters(threadID: "origin", name: "call_agent_result", payload: ["value": Double.nan]))
        XCTAssertThrowsError(try CodexCallbackWire.parameters(threadID: "origin", name: "call_agent_result",
            payload: ["value": String(repeating: "x", count: CodexCallbackWire.maximumLineBytes)]))
    }
    func testChildEnvironmentKeepsProxyContextAndDropsCredentials() {
        let cleaned = CodexCallbackWire.childEnvironment([
            "OPENAI_API_KEY": "secret", "ANTHROPIC_API_KEY": "secret", "GITHUB_TOKEN": "secret",
            "AWS_SECRET_ACCESS_KEY": "secret", "MY_PASSWORD": "secret", "OPENAI_BASE_URL": "secret",
            "DYLD_INSERT_LIBRARIES": "secret", "CODEX_BIN": "/untrusted/tool",
            "CODEX_APP_SERVER_SOCKET": "/tmp/codex.sock", "HOME": "/home/example", "PATH": "/bin"
        ])
        XCTAssertEqual(cleaned, ["CODEX_APP_SERVER_SOCKET": "/tmp/codex.sock", "HOME": "/home/example", "PATH": "/bin"])
    }
    func testInitializeResumeAndTurnStartUseTheSameOrigin() async throws {
        let transport = ScriptedCodexTransport()
        transport.handler = { $1.respondNormally($0) }
        let client = CodexCallbackClient(timeoutNanoseconds: 1_000_000_000, transport: { transport })
        let turn = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: ["result": "finished"])
        XCTAssertEqual(turn, "turn-test")
        let messages = transport.messages
        XCTAssertEqual(messages.compactMap { $0["method"] as? String }, ["initialize", "initialized", "thread/resume", "turn/start"])
        let capabilities = (messages[0]["params"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertEqual(capabilities?["experimentalApi"] as? Bool, true)
        XCTAssertEqual((messages[2]["params"] as? [String: Any])?["threadId"] as? String, "origin")
        XCTAssertEqual((messages[2]["params"] as? [String: Any])?["excludeTurns"] as? Bool, true)
        XCTAssertEqual((messages[3]["params"] as? [String: Any])?["threadId"] as? String, "origin")
        await client.close()
        XCTAssertTrue(transport.wasClosed)
    }
    func testSequentialDeliveriesMayUseDistinctLedgerOrigins() async throws {
        let transport = ScriptedCodexTransport()
        transport.handler = { $1.respondNormally($0) }
        let client = CodexCallbackClient(timeoutNanoseconds: 1_000_000_000, transport: { transport })
        _ = try await client.deliver(threadID: "first", name: "call_agent_question", payload: [:])
        _ = try await client.deliver(threadID: "second", name: "call_agent_result", payload: [:])
        let starts = transport.messages.filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual(starts.compactMap { ($0["params"] as? [String: Any])?["threadId"] as? String }, ["first", "second"])
        XCTAssertEqual(transport.messages.filter { $0["method"] as? String == "initialize" }.count, 1)
        await client.close()
    }
    func testTurnTimeoutIsUncertainAndNeverRetried() async {
        let transport = ScriptedCodexTransport()
        transport.handler = { request, server in
            if request["method"] as? String != "turn/start" { server.respondNormally(request) }
        }
        let client = CodexCallbackClient(timeoutNanoseconds: 20_000_000, transport: { transport })
        do {
            _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:])
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CodexCallbackError, .timedOut(method: "turn/start", deliveryUncertain: true))
        }
        XCTAssertEqual(transport.messages.filter { $0["method"] as? String == "turn/start" }.count, 1)
        XCTAssertTrue(transport.wasClosed)
        await client.close()
    }
    func testInitializeTimeoutDidNotSubmitCallback() async {
        let transport = ScriptedCodexTransport()
        let client = CodexCallbackClient(timeoutNanoseconds: 20_000_000, transport: { transport })
        do {
            _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:])
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CodexCallbackError, .timedOut(method: "initialize", deliveryUncertain: false))
        }
        XCTAssertFalse(transport.messages.contains { $0["method"] as? String == "turn/start" })
        await client.close()
    }
    func testCancellationDuringInitializeUnblocksShutdownPromptly() async {
        let transport = ScriptedCodexTransport()
        let started = expectation(description: "initialize submitted")
        transport.handler = { request, _ in
            if request["method"] as? String == "initialize" { started.fulfill() }
        }
        let client = CodexCallbackClient(timeoutNanoseconds: 5_000_000_000, transport: { transport })
        let task = Task { try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:]) }
        await fulfillment(of: [started], timeout: 1)
        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? CodexCallbackError, .cancelled(deliveryUncertain: false)) }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
        XCTAssertTrue(transport.wasClosed)
        XCTAssertFalse(transport.messages.contains { $0["method"] as? String == "turn/start" })
        await client.close()
    }
    func testCancellationAfterTurnSubmissionPreservesUncertainty() async {
        let transport = ScriptedCodexTransport()
        let submitted = expectation(description: "turn submitted")
        transport.handler = { request, server in
            if request["method"] as? String == "turn/start" { submitted.fulfill() }
            else { server.respondNormally(request) }
        }
        let client = CodexCallbackClient(timeoutNanoseconds: 5_000_000_000, transport: { transport })
        let task = Task { try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:]) }
        await fulfillment(of: [submitted], timeout: 1)
        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue((error as? CodexCallbackError)?.deliveryUncertain == true) }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
        XCTAssertEqual(transport.messages.filter { $0["method"] as? String == "turn/start" }.count, 1)
        await client.close()
    }
    func testServerApprovalGetsExplicitUnsupportedReply() async throws {
        let transport = ScriptedCodexTransport()
        transport.handler = { request, server in
            if request["method"] as? String == "turn/start" {
                server.emit(["id": "approval-1", "method": "item/commandExecution/requestApproval", "params": ["command": "never execute"]])
            }
            server.respondNormally(request)
        }
        let client = CodexCallbackClient(timeoutNanoseconds: 1_000_000_000, transport: { transport })
        _ = try await client.deliver(threadID: "origin", name: "call_agent_question", payload: [:])
        let refusal = try XCTUnwrap(transport.messages.first { $0["id"] as? String == "approval-1" })
        XCTAssertEqual((refusal["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNil(refusal["result"])
        await client.close()
    }
    func testResumeIdentityMismatchDoesNotSendTurn() async {
        let transport = ScriptedCodexTransport()
        transport.handler = { request, server in
            if request["method"] as? String == "thread/resume" {
                server.emit(["id": request["id"]!, "result": ["thread": ["id": "wrong-task"]]])
            } else { server.respondNormally(request) }
        }
        let client = CodexCallbackClient(timeoutNanoseconds: 1_000_000_000, transport: { transport })
        do {
            _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:])
            XCTFail("Expected identity rejection")
        } catch { XCTAssertEqual(error as? CodexCallbackError, .protocolViolation) }
        XCTAssertFalse(transport.messages.contains { $0["method"] as? String == "turn/start" })
        await client.close()
    }
    func testDisconnectAfterTurnSubmissionIsUncertain() async {
        let transport = ScriptedCodexTransport()
        transport.handler = { request, server in
            if request["method"] as? String == "turn/start" { server.disconnect() }
            else { server.respondNormally(request) }
        }
        let client = CodexCallbackClient(timeoutNanoseconds: 1_000_000_000, transport: { transport })
        do {
            _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:])
            XCTFail("Expected disconnect")
        } catch { XCTAssertEqual(error as? CodexCallbackError, .disconnected(deliveryUncertain: true)) }
        await client.close()
    }
    func testServerRejectionOmitsServerContent() async {
        let transport = ScriptedCodexTransport()
        transport.handler = { request, server in
            if request["method"] as? String == "turn/start" {
                server.emit(["id": request["id"]!, "error": ["code": -32602, "message": "private body must not be displayed"]])
            } else { server.respondNormally(request) }
        }
        let client = CodexCallbackClient(timeoutNanoseconds: 1_000_000_000, transport: { transport })
        do {
            _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:])
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? CodexCallbackError, .rejected(method: "turn/start", code: -32602))
            XCTAssertFalse(error.localizedDescription.contains("private body"))
        }
        await client.close()
    }
}
