import XCTest
import CallAudioDSP
@testable import CallAudio

final class RuntimeContractsTests: XCTestCase {
    func testExactCallerAttributionRejectsAmbiguityAndNeverFallsBack() throws {
        let renderer = CallAudioProcess(id: 42, bundleID: "com.apple.avconferenced", runningOutput: true)
        let chrome = CallAudioProcess(id: 44, bundleID: "com.google.Chrome", runningOutput: true)
        XCTAssertEqual(try CallAudioAttribution.select(processes: [renderer, chrome], phoneRunning: true, faceTimeRunning: false), 42)
        XCTAssertThrowsError(try CallAudioAttribution.select(processes: [chrome], phoneRunning: true, faceTimeRunning: false))
        XCTAssertThrowsError(try CallAudioAttribution.select(processes: [renderer], phoneRunning: false, faceTimeRunning: false))
        XCTAssertThrowsError(try CallAudioAttribution.select(processes: [renderer], phoneRunning: true, faceTimeRunning: true))
        let second = CallAudioProcess(id: 45, bundleID: "com.apple.mobilephone", runningOutput: true)
        XCTAssertThrowsError(try CallAudioAttribution.select(processes: [renderer, second], phoneRunning: true, faceTimeRunning: false))
    }
    func testModesHaveIndependentAuthorizedRoutes() {
        XCTAssertEqual(CallAudioMode.agent.routes.rawValue, 54)
        XCTAssertEqual(CallAudioMode.join.routes, .all)
        XCTAssertEqual(CallAudioMode.takeOver.routes.rawValue, 17)
        XCTAssertEqual(CallAudioMode.privateAside.routes.rawValue, 56)
        XCTAssertFalse(CallAudioMode.privateAside.routes.contains(.microphoneToCaller))
        XCTAssertFalse(CallAudioMode.privateAside.routes.contains(.agentToCaller))
        XCTAssertFalse(CallAudioMode.takeOver.routes.contains(.callerToAgent))
    }
    func testInjectedModelSinkCannotReceiveForbiddenParticipant() throws {
        var delivered = Data()
        ModelFrameMixer.render(caller: [0.25, 0.25], microphone: [0.75, 0.75], frames: 2,
            routes: CallAudioMode.agent.routes, callerGain: 1, microphoneGain: 1) { delivered = $0 }
        XCTAssertEqual(try PCM24.decode(delivered), [0.25, 0.25])
        ModelFrameMixer.render(caller: [0.25, 0.25], microphone: [0.75, 0.75], frames: 2,
            routes: CallAudioMode.privateAside.routes, callerGain: 1, microphoneGain: 1) { delivered = $0 }
        XCTAssertEqual(try PCM24.decode(delivered), [0.75, 0.75])
        ModelFrameMixer.render(caller: [1, .infinity], microphone: [1, .nan], frames: 2,
            routes: .all, callerGain: 1, microphoneGain: 1) { delivered = $0 }
        let values = try PCM24.decode(delivered)
        XCTAssertEqual(values[0], 32767.0 / 32768.0)
        XCTAssertEqual(values[1], 0)
    }
    func testEpochAndMonotonicSequenceRejectLateSpeech() throws {
        var gate = StreamGate()
        gate.transition(to: "old")
        try gate.accept(epoch: "old", sequence: 1)
        XCTAssertThrowsError(try gate.accept(epoch: "old", sequence: 1))
        XCTAssertThrowsError(try gate.accept(epoch: "old", sequence: 0))
        gate.transition(to: "new")
        XCTAssertThrowsError(try gate.accept(epoch: "old", sequence: 100))
        try gate.accept(epoch: "new", sequence: 0)
        gate.transition(to: "")
        XCTAssertThrowsError(try gate.accept(epoch: "", sequence: 0))
    }
    func testNoDeviceCallsForInvalidConfigurationOrDisconnectedSubmission() {
        XCTAssertThrowsError(try CallAudioRuntime.preflight(CallAudioConfiguration(virtualOutputUID: "")))
        XCTAssertThrowsError(try CallAudioRuntime.preflight(CallAudioConfiguration(virtualOutputUID: "default")))
        let runtime = CallAudioRuntime()
        runtime.setSendMuted(true)
        XCTAssertThrowsError(try runtime.submitAgentPCM(Data([0, 0]), epoch: "old", sequence: 0))
        runtime.stop()
    }
    func testPCMRejectsMalformedAndOversizedPackets() {
        XCTAssertThrowsError(try PCM24.decode(Data()))
        XCTAssertThrowsError(try PCM24.decode(Data([0])))
        XCTAssertThrowsError(try PCM24.decode(Data(repeating: 0, count: 48002)))
    }
    func testBufferFaultPolicyRejectsOverflowAndStaleWork() throws {
        try AudioBufferHealth.validate(overflowFrames: 0, workerDelay: 0.02)
        try AudioBufferHealth.validate(overflowFrames: 0, workerDelay: 0.5)
        XCTAssertThrowsError(try AudioBufferHealth.validate(overflowFrames: 1, workerDelay: 0.02))
        XCTAssertThrowsError(try AudioBufferHealth.validate(overflowFrames: 0, workerDelay: 0.501))
        XCTAssertThrowsError(try AudioBufferHealth.validate(overflowFrames: 0, workerDelay: .nan))
        XCTAssertThrowsError(try AudioBufferHealth.validate(overflowFrames: 0, workerDelay: 0.02, captureBacklog: 0.501))
    }
    func testCancelledQueuedStartCannotReopenDevices() {
        let runtime = CallAudioRuntime()
        let revision = runtime.lifecycleRevision
        runtime.stopAsync()
        XCTAssertThrowsError(try runtime.start(configuration: .init(virtualOutputUID: "never-look-up-this-device"),
            epoch: "test", expectedLifecycleRevision: revision)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cancelled before execution"))
        }
        runtime.stop()
    }
    func testWorkerConverterRetainsContinuityAcrossChunks() throws {
        let converter = try MonoConverter(from: 48000, to: 24000)
        var output: [Float] = []
        for block in 0..<50 {
            let samples = (0..<960).map { Float(0.25 * sin(2 * Double.pi * 440 * Double(block * 960 + $0) / 48000)) }
            output += try converter.convert(samples)
        }
        XCTAssertGreaterThan(output.count, 23500)
        XCTAssertLessThanOrEqual(output.count, 24128)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        let rms = sqrt(output.reduce(Float(0)) { $0 + $1 * $1 } / Float(output.count))
        XCTAssertEqual(rms, 0.25 / sqrt(2), accuracy: 0.01)
        converter.reset()
        let silence = try converter.convert([Float](repeating: 0, count: 960))
        XCTAssertTrue(silence.allSatisfy { abs($0) < 0.00001 })
    }
}
