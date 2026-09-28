import Foundation
import XCTest
@testable import CallVoice

final class LiveProtocolTests: XCTestCase {
    private func decode(_ value: [String: Any]) throws -> LiveVoiceEvent {
        try LiveProtocol.decode(JSONSerialization.data(withJSONObject: value))
    }
    func testWireMessagesAcceptPCMAndRejectCorruptAudio() throws {
        let pcm = Data([0, 32, 0, 64])
        XCTAssertEqual(try decode(["type": "session.output_audio.delta", "delta": pcm.base64EncodedString()]), .audio(pcm))
        for bad in ["", "AA==", "AAAA\n", "!not-audio", Data(repeating: 0, count: 48002).base64EncodedString()] {
            XCTAssertThrowsError(try decode(["type": "session.output_audio.delta", "delta": bad]))
        }
        XCTAssertEqual(try decode(["type": "session.started"]), .ready)
        XCTAssertEqual(try decode(["type": "session.closed"]), .closed)
        XCTAssertEqual(try decode(["type": "session.input_transcript.delta", "delta": "caller"]), .transcript("caller", isAssistant: false))
        XCTAssertEqual(try decode(["type": "session.output_transcript.delta", "delta": "assistant"]), .transcript("assistant", isAssistant: true))
        XCTAssertEqual(try decode(["type": "future.event"]), .ignored)
        XCTAssertThrowsError(try LiveProtocol.decode(Data(repeating: 32, count: 262145)))
    }
    func testDelegateUsesSolAtLowReasoningEffort() throws {
        guard ProcessInfo.processInfo.environment["DELEGATE_MODEL"] == nil,
              ProcessInfo.processInfo.environment["DELEGATE_REASONING_EFFORT"] == nil else {
            throw XCTSkip("Delegate settings are overridden in this environment.")
        }
        let start = LiveProtocol.start(instructions: "Call", context: "", delegationEnabled: true)
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: start, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertTrue(wire.contains(#""model":"gpt-6-sol""#), wire)
        XCTAssertTrue(wire.contains(#""reasoning":{"effort":"low"}"#), wire)
    }
    func testSessionHistoryIsBoundedAndSeparateFromInstructions() throws {
        let start = LiveProtocol.start(instructions: "Owner took over. Do not speak.", context: String(repeating: "x", count: 20000))
        let session = try XCTUnwrap(start["session"] as? [String: Any])
        XCTAssertEqual(session["store"] as? Bool, false)
        XCTAssertEqual(session["instructions"] as? String, "Owner took over. Do not speak.")
        let history = try XCTUnwrap(session["input"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0]["role"] as? String, "user")
        let content = try XCTUnwrap(history[0]["content"] as? [[String: String]])
        XCTAssertTrue(content[0]["text"]!.hasSuffix(String(repeating: "x", count: 12000)))
        XCTAssertLessThan(content[0]["text"]!.count, 12300)
        XCTAssertNil(LiveProtocol.start(instructions: "task", context: "")["input"])
    }
    func testProviderErrorsDoNotExposeKeys() throws {
        XCTAssertEqual(try decode(["type": "error", "error": ["message": "Invalid sk-test_SECRET-123"]]), .error("Invalid [redacted]"))
    }
    func testCancelledSessionCannotOpenOrSend() async {
        let session = LiveVoiceSession(audio: { _ in XCTFail("Closed sessions must not deliver audio") })
        await session.close()
        do { try await session.connect(key: "synthetic-key", instructions: "test"); XCTFail("Must reject reuse") } catch {}
        do { try await session.sendInput("AAA="); XCTFail("Must reject disconnected input") } catch {}
    }
}
