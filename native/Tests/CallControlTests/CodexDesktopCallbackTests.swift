import Darwin
import Foundation
import XCTest
@testable import CallControl

private final class ScriptedDesktopConnection: CodexDesktopConnection, @unchecked Sendable {
    private let condition = NSCondition()
    private var replies: [[String: Any]] = []
    private var requests: [[String: Any]] = []
    private var cancelled = false
    private var timedOut = false
    private var closed = false
    let clientID = UUID().uuidString
    let ownerID = UUID().uuidString
    var callbackError: String?
    var ownerSupportsInput = true
    var wrongOwner = false
    var timeoutCallback = false
    var pauseCallback = false
    var onCallback: (() -> Void)?
    var messages: [[String: Any]] { condition.lock(); defer { condition.unlock() }; return requests }
    var wasClosed: Bool { condition.lock(); defer { condition.unlock() }; return closed }
    func start() throws {}
    func write(_ frame: Data, deadline: TimeInterval) throws {
        let size = try CodexDesktopWire.frameSize(frame.prefix(4))
        guard frame.count == size + 4 else { throw CodexCallbackError.protocolViolation }
        let request = try JSONSerialization.jsonObject(with: frame.dropFirst(4)) as! [String: Any]
        condition.lock(); requests.append(request); condition.unlock()
        guard request["type"] as? String == "request", let method = request["method"] as? String else { return }
        var response: [String: Any] = ["type": "response", "requestId": request["requestId"]!, "method": method,
            "resultType": "success", "handledByClientId": ownerID]
        switch method {
        case "initialize": response["handledByClientId"] = clientID; response["result"] = ["clientId": clientID]
        case "thread-owner-discovery": response["result"] = ["supportsUntrustedAppInput": ownerSupportsInput]
        case "thread-follower-start-turn":
            onCallback?()
            if pauseCallback { return }
            if timeoutCallback { condition.lock(); timedOut = true; condition.signal(); condition.unlock(); return }
            if let callbackError { response = ["type": "response", "requestId": request["requestId"]!, "resultType": "error", "error": callbackError] }
            else { response["result"] = ["result": ["turn": ["id": "desktop-turn"]]] }
            if wrongOwner { response["handledByClientId"] = UUID().uuidString }
        default: throw CodexCallbackError.protocolViolation
        }
        condition.lock(); replies.append(response); condition.signal(); condition.unlock()
    }
    func read(deadline: TimeInterval) throws -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        while replies.isEmpty && !cancelled && !timedOut {
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true }
        }
        if cancelled { throw CodexCallbackError.cancelled(deliveryUncertain: false) }
        if timedOut { throw CodexCallbackError.timedOut(method: "fake desktop", deliveryUncertain: false) }
        return replies.removeFirst()
    }
    func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    func close() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
}

final class CodexDesktopCallbackTests: XCTestCase {
    func testSingleTargetedMutationPreservesExternalToolIdentity() async throws {
        let connection = ScriptedDesktopConnection()
        let client = CodexDesktopCallback(connection: { connection })
        let turn = try await client.deliver(threadID: "origin", name: "call_agent_question", payload: ["threadId": "untrusted", "question": "question"])
        XCTAssertEqual(turn, "desktop-turn")
        let messages = connection.messages
        XCTAssertEqual(messages.compactMap { $0["method"] as? String }, ["initialize", "thread-owner-discovery", "thread-follower-start-turn"])
        XCTAssertEqual(messages.compactMap { $0["version"] as? Int }, [0, 1, 2])
        XCTAssertEqual((messages[1]["params"] as? [String: Any])?["hostId"] as? String, "local")
        let mutation = messages[2]
        XCTAssertEqual(mutation["targetClientId"] as? String, connection.ownerID)
        XCTAssertNil(mutation["hostId"])
        XCTAssertEqual((mutation["params"] as? [String: Any])?["conversationId"] as? String, "origin")
        let turnStart = (mutation["params"] as? [String: Any])?["turnStart"] as? [String: Any]
        let request = try XCTUnwrap(turnStart?["request"] as? [String: Any])
        XCTAssertEqual(request["threadId"] as? String, "origin")
        XCTAssertEqual((request["input"] as? [Any])?.count, 0)
        XCTAssertEqual((request["toolOutput"] as? [String: Any])?["name"] as? String, "call_agent_question")
        XCTAssertEqual((request["toolOutput"] as? [String: Any])?["namespace"] as? String, "codex_call")
        XCTAssertTrue(connection.wasClosed)
    }
    func testUnsupportedOwnerCapabilityPreventsMutation() async {
        let connection = ScriptedDesktopConnection(); connection.ownerSupportsInput = false
        let client = CodexDesktopCallback(connection: { connection })
        do { _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:]); XCTFail("Expected incompatibility") }
        catch { XCTAssertEqual(error as? CodexCallbackError, .desktopIncompatible) }
        XCTAssertEqual(connection.messages.count, 2)
    }
    func testUnsupportedVersionIsExplicitNondeliveryWithoutRetry() async {
        let connection = ScriptedDesktopConnection(); connection.callbackError = "request-version-mismatch"
        let client = CodexDesktopCallback(connection: { connection })
        do { _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:]); XCTFail("Expected version failure") }
        catch {
            XCTAssertEqual(error as? CodexCallbackError, .desktopRejected("request-version-mismatch"))
            XCTAssertFalse((error as? CodexCallbackError)?.deliveryUncertain ?? true)
        }
        XCTAssertEqual(connection.messages.filter { $0["method"] as? String == "thread-follower-start-turn" }.count, 1)
    }
    func testTimeoutAfterMutationIsUncertainWithoutRetry() async {
        let connection = ScriptedDesktopConnection(); connection.timeoutCallback = true
        let client = CodexDesktopCallback(connection: { connection })
        do { _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:]); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? CodexCallbackError, .timedOut(method: "desktop callback", deliveryUncertain: true)) }
        XCTAssertEqual(connection.messages.filter { $0["method"] as? String == "thread-follower-start-turn" }.count, 1)
    }
    func testWrongMutationResponderCannotConfirmDelivery() async {
        let connection = ScriptedDesktopConnection(); connection.wrongOwner = true
        let client = CodexDesktopCallback(connection: { connection })
        do { _ = try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:]); XCTFail("Expected owner mismatch") }
        catch { XCTAssertEqual(error as? CodexCallbackError, .disconnected(deliveryUncertain: true)) }
    }
    func testCancellationShutsDownWaitingDelivery() async {
        let connection = ScriptedDesktopConnection(); connection.pauseCallback = true
        let submitted = expectation(description: "callback dispatched")
        connection.onCallback = { submitted.fulfill() }
        let client = CodexDesktopCallback(connection: { connection })
        let task = Task { try await client.deliver(threadID: "origin", name: "call_agent_result", payload: [:]) }
        await fulfillment(of: [submitted], timeout: 1)
        let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? CodexCallbackError, .cancelled(deliveryUncertain: true)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testFrameHeaderIsLittleEndianAndRejectsOversizedAllocation() throws {
        let frame = try CodexDesktopWire.frame(["hello": "world"])
        XCTAssertEqual(try CodexDesktopWire.frameSize(frame.prefix(4)), frame.count - 4)
        XCTAssertEqual(frame[0], UInt8(frame.count - 4))
        XCTAssertNotEqual(frame.last, 10)
        XCTAssertThrowsError(try CodexDesktopWire.frameSize(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try CodexDesktopWire.frameSize(Data([255, 255, 255, 255])))
        XCTAssertThrowsError(try CodexDesktopWire.frameSize(Data([1, 2])))
    }
    func testEndpointRejectsRegularFilesAndForeignOwnership() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ccd-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ipc.sock")
        try Data().write(to: path)
        XCTAssertThrowsError(try CodexDesktopEndpoint.validate(path))
        try FileManager.default.removeItem(at: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { XCTFail("Socket test path too long"); return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }}
        XCTAssertEqual(status, 0); XCTAssertEqual(chmod(path.path, 0o600), 0)
        XCTAssertNoThrow(try CodexDesktopEndpoint.validate(path))
        XCTAssertThrowsError(try CodexDesktopEndpoint.validate(path, uid: getuid() + 1))
    }
}
