import XCTest
@testable import CallControl

final class PhoneSessionTests: XCTestCase {
    private let input: [String: Any] = ["codex_task_id": "01a0b80d-4fe8-7622-80c4-526a60b1db45",
        "request_id": "test-one", "task": "Ask whether an appointment is available."]
    func testRetryCannotCreateAnotherSessionOrRetargetOrigin() throws {
        let registry = PhoneSessionRegistry()
        let first = try registry.create(arguments: input)
        XCTAssertEqual(try registry.create(arguments: input).sessionID, first.sessionID)
        var changed = input; changed["codex_task_id"] = "another-thread"
        XCTAssertThrowsError(try registry.create(arguments: changed))
        XCTAssertEqual(registry.current?.originThreadID, first.originThreadID)
    }
    func testWithoutRequestIDEachStartPreparesANewCall() throws {
        let registry = PhoneSessionRegistry()
        var arguments = input; arguments.removeValue(forKey: "request_id")
        let first = try registry.create(arguments: arguments)
        try registry.update(first.sessionID) { $0.phase = "ended" }
        XCTAssertNotEqual(try registry.create(arguments: arguments).sessionID, first.sessionID)
    }
    func testEndedSessionCannotControlReplacement() throws {
        let registry = PhoneSessionRegistry()
        let old = try registry.create(arguments: input)
        var next = input; next["request_id"] = "test-two"
        XCTAssertThrowsError(try registry.create(arguments: next))
        try registry.update(old.sessionID) { $0.phase = "disconnecting" }
        XCTAssertThrowsError(try registry.requireCurrent(old.sessionID))
        try registry.update(old.sessionID) { $0.phase = "ended" }
        let replacement = try registry.create(arguments: next)
        XCTAssertThrowsError(try registry.requireCurrent(old.sessionID))
        XCTAssertEqual(try registry.requireCurrent(replacement.sessionID).sessionID, replacement.sessionID)
        XCTAssertEqual(try registry.create(arguments: input).sessionID, old.sessionID)
        XCTAssertEqual(registry.currentID, replacement.sessionID)
    }
    func testRejectsMalformedOriginAndOversizedTask() {
        for (field, bad) in [("codex_task_id", "task?redirect=elsewhere"), ("request_id", ""), ("task", String(repeating: "x", count: 16001))] {
            var invalid = input; invalid[field] = bad
            XCTAssertThrowsError(try PhoneSessionRegistry().create(arguments: invalid))
        }
    }
    func testCallMetadataNeverClaimsDialedOrConnected() throws {
        let session = try PhoneSessionRegistry().create(arguments: input)
        XCTAssertEqual(session.phase, "prepared")
        XCTAssertEqual(session.json["dialing"] as? String, "manual")
        XCTAssertEqual(session.json["hangup"] as? String, "manual")
        XCTAssertEqual(session.json["origin_thread_id"] as? String, input["codex_task_id"] as? String)
    }
}
