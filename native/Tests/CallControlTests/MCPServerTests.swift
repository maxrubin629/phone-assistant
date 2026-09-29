import Foundation
import Darwin
import XCTest
@testable import CallControl

final class MCPServerTests: XCTestCase {
    private func ready(_ server: MCPServer) {
        let response = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]])
        XCTAssertEqual((response?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testDiscoveryAndInitializationDoNotTouchApp() throws {
        let server = MCPServer { _ in XCTFail("Discovery must not change the app"); return [:] }
        XCTAssertNotNil(server.handle(["jsonrpc": "2.0", "id": 0, "method": "tools/list"])?["error"])
        ready(server)
        let response = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try XCTUnwrap((response?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       Set(["call_start", "call_get", "call_transcript", "call_dial", "call_connect", "call_set_mode", "call_answer_question", "call_end"]))
        // Dialing uses only the prepared session's number, never a new destination.
        let dial = try XCTUnwrap(tools.first { ($0["name"] as? String) == "call_dial" })
        let schema = try XCTUnwrap(dial["inputSchema"] as? [String: Any])
        XCTAssertEqual((schema["properties"] as? [String: Any])?.keys.sorted(), ["session_id"])
    }

    func testToolArgumentsForwardExactlyAndAppErrorsBecomeToolErrors() throws {
        var forwarded = [[String: Any]]()
        let server = MCPServer { command in forwarded.append(command); return ["session_id": "session", "status": "prepared"] }
        ready(server)
        let arguments: [String: Any] = ["codex_task_id": "origin", "request_id": "retry-1", "task": "Ask about an appointment"]
        let response = server.handle(["jsonrpc": "2.0", "id": "start", "method": "tools/call",
            "params": ["name": "call_start", "arguments": arguments]])
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded[0]["action"] as? String, "call_start")
        XCTAssertEqual((forwarded[0]["arguments"] as? [String: String])?["codex_task_id"], "origin")
        XCTAssertEqual((response?["result"] as? [String: Any])?["isError"] as? Bool, false)
        let failing = MCPServer { _ in ["error": "Phone is not connected"] }
        ready(failing)
        let failure = failing.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "call_connect", "arguments": ["session_id": "session"]]])
        XCTAssertEqual((failure?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testInvalidArgumentsAndNotificationsCannotReachApp() {
        let server = MCPServer { _ in XCTFail("Invalid request reached app"); return [:] }
        ready(server)
        let invalid: [(String, [String: Any])] = [
            ("call_start", ["task": "Call"]),
            ("call_start", ["task": "Call", "codex_task_id": "origin", "dial": "yes"]),
            ("call_start", ["task": " ", "codex_task_id": "origin", "request_id": "r"]),
            ("call_start", ["task": "Call", "codex_task_id": "origin", "request_id": "r", "phone_number": "tel:1;open"]),
            ("call_set_mode", ["session_id": "s", "mode": "anything"]),
            ("call_answer_question", ["session_id": "s", "question_id": "q", "answer": true]),
            ("call_get", ["admin": true]),
            ("call_transcript", ["page": "0"]),
            ("call_transcript", ["page": "two"])
        ]
        for (name, args) in invalid {
            let response = server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": name, "arguments": args]])
            XCTAssertEqual((response?["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "tools/call",
            "params": ["name": "call_end", "arguments": ["session_id": "s"]]]))
    }

    func testStdioPipesHandleInitializationMalformedJSONAndRecovery() throws {
        let input = Pipe(), output = Pipe()
        let lines: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "call_get"]]
        ]
        for line in lines { try input.fileHandleForWriting.write(contentsOf: PhoneControlProtocol.encode(line)) }
        try input.fileHandleForWriting.write(contentsOf: Data("not json\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\n".utf8))
        try input.fileHandleForWriting.close()
        try MCPServer { _ in ["status": "idle"] }.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let responses = try output.fileHandleForReading.readToEnd()!.split(separator: 10).map { try PhoneControlProtocol.decode(Data($0)) }
        XCTAssertEqual(responses.count, 4)
        XCTAssertEqual(((responses[1]["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["status"] as? String, "idle")
        XCTAssertEqual((responses[2]["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual(responses[3]["id"] as? Int, 3)
        XCTAssertNotNil(responses[3]["result"])
    }

    func testInteractiveStdioRepliesWhileClientKeepsInputOpen() throws {
        let input = Pipe(), output = Pipe(), finished = expectation(description: "stdio stopped")
        let server = MCPServer { _ in [:] }
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do { try server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
            catch { XCTFail("Stdio failed: \(error)") }
        }
        try input.fileHandleForWriting.write(contentsOf: PhoneControlProtocol.encode([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]]))
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 1000)
        // Closing input before polling would miss buffering deadlocks with actual MCP clients.
        XCTAssertEqual(ready, 1)
        if ready == 1 {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            XCTAssertGreaterThan(count, 0)
            if count > 0 {
                let response = try PhoneControlProtocol.decode(Data(bytes.prefix(count)))
                XCTAssertEqual(response["id"] as? Int, 1)
            }
        }
        try input.fileHandleForWriting.close()
        wait(for: [finished], timeout: 2)
        try output.fileHandleForWriting.close()
    }

    func testFramingBoundsAndJSONObjectRequirement() {
        XCTAssertThrowsError(try PhoneControlProtocol.encode(["oversized": String(repeating: "x", count: 128 * 1024)]))
        XCTAssertThrowsError(try PhoneControlProtocol.decode(Data("[]".utf8)))
        XCTAssertThrowsError(try PhoneControlProtocol.decode(Data("null".utf8)))
    }

    func testLargeResponsesStayBoundedWithoutTerminatingMCP() throws {
        var payload: [String: Any] = ["task": String(repeating: "x", count: 48000)]
        let server = MCPServer { _ in payload }
        ready(server)
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "call_get"]]
        let large = try XCTUnwrap(server.handle(call))
        XCTAssertNil((large["result"] as? [String: Any])?["structuredContent"])
        XCTAssertLessThan(try PhoneControlProtocol.encode(large).count, PhoneControlProtocol.maximumFrameBytes)
        payload = ["task": String(repeating: "\"", count: 40000)]
        let overflow = try XCTUnwrap(server.handle(call))
        XCTAssertEqual((overflow["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertLessThan(try PhoneControlProtocol.encode(overflow).count, PhoneControlProtocol.maximumFrameBytes)
    }
}
