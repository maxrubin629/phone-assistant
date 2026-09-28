import XCTest
import CallAudioDSP
@testable import CallAudio

final class CallAudioTuningTests: XCTestCase {
    func testNativePlaybackDoesNotKeepAnUnneededSpeakerClientAndPreservesAgentMonitoring() {
        let me = CallAudioConfiguration(virtualOutputUID: "test", microphoneEnabled: true,
            manageCallerListening: false, phoneRouting: .init(speaker: .user, listener: .user))
        XCTAssertFalse(me.needsListeningDevice)
        var withAgent = me; withAgent.phoneRouting = .init(speaker: .both, listener: .user)
        XCTAssertTrue(withAgent.needsListeningDevice)
        var managed = me; managed.manageCallerListening = true
        XCTAssertTrue(managed.needsListeningDevice)
    }
    func testDiagnosticControlsCannotBroadenAnyPhoneRoutingCombination() {
        for speaker in PhoneParticipant.allCases {
            for listener in PhoneParticipant.allCases {
                let authorized = PhoneRouting(speaker: speaker, listener: listener).routes
                var tuning = CallAudioTuning(microphoneGain: 3)
                for path in CallAudioTuning.Path.allCases {
                    tuning[path] = 4
                    tuning.setMuted(true, path: path)
                    let effective = tuning.effectiveRoutes(authorized)
                    XCTAssertTrue(effective.subtracting(authorized).isEmpty)
                    XCTAssertFalse(effective.contains(path.route))
                }
                XCTAssertTrue(tuning.effectiveRoutes(authorized).isEmpty)
            }
        }
    }
    func testInvalidAndOversizedControlsAreBoundedAndRoundTrip() throws {
        var tuning = CallAudioTuning(microphoneGain: 3)
        tuning[.agentToCaller] = .infinity
        tuning[.agentToUser] = 100
        tuning.limiterCeiling = .nan; tuning.limiterReleaseMS = -10
        tuning = tuning.normalized()
        XCTAssertEqual(tuning[.microphoneToCaller], 3)
        XCTAssertEqual(tuning[.microphoneToAgent], 3)
        XCTAssertEqual(tuning[.agentToCaller], 0)
        XCTAssertEqual(tuning[.agentToUser], 4)
        XCTAssertEqual(tuning.limiterCeiling, 0.98)
        XCTAssertEqual(tuning.limiterReleaseMS, 10)
        let data = try JSONEncoder().encode(tuning)
        XCTAssertEqual(try JSONDecoder().decode(CallAudioTuning.self, from: data), tuning)
    }
    func testLiveControlsRespectSendMuteAndLifecycleCancellation() throws {
        let controls = AudioControls()
        cab_controls_set_routes(controls.pointer, CallAudioRoutes.all.rawValue)
        var tuning = CallAudioTuning(microphoneGain: 4)
        tuning.limiterEnabled = false; tuning.apply(to: controls.pointer)
        XCTAssertEqual(cab_controls_snapshot(controls.pointer).routes & CallAudioRoutes.microphoneToCaller.rawValue, 0)
        cab_controls_set_send_muted(controls.pointer, false)
        XCTAssertNotEqual(cab_controls_snapshot(controls.pointer).routes & CallAudioRoutes.microphoneToCaller.rawValue, 0)
        cab_controls_cancel(controls.pointer)
        tuning.apply(to: controls.pointer)
        XCTAssertEqual(cab_controls_snapshot(controls.pointer).routes, 0)
    }
}
