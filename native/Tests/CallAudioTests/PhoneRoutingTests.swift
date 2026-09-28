import XCTest
import CallAudioDSP
@testable import CallAudio

final class PhoneRoutingTests: XCTestCase {
    func testAllNineDirectionsThroughProductionMixers() throws {
        for speaker in PhoneParticipant.allCases {
            for listener in PhoneParticipant.allCases {
                let policy = PhoneRouting(speaker: speaker, listener: listener)
                let controls = AudioControls()
                cab_controls_set_routes(controls.pointer, policy.routes.rawValue)
                cab_controls_set_send_muted(controls.pointer, false)
                let routes = cab_controls_snapshot(controls.pointer).routes
                let mic: [Float] = [0.125], agent: [Float] = [0.25], caller: [Float] = [0.5]
                var phone: [Float] = [0], monitor: [Float] = [0], pcm = Data()
                cab_mix_mono(mic, agent, &phone, nil, 1, 1, 1, 1, routes)
                cab_mix_monitor(caller, agent, nil, &monitor, 1, 1, 1, routes)
                ModelFrameMixer.render(caller: caller, microphone: mic, frames: 1, routes: policy.routes,
                    callerGain: 1, microphoneGain: 1) { pcm = $0 }
                let outgoing: Float = (speaker.includesUser ? 0.125 : 0) + (speaker.includesAgent ? 0.25 : 0)
                let listening: Float = listener.includesUser ? 0.5 + (speaker.includesAgent ? 0.25 : 0) : 0
                let model: Float = listener.includesAgent ? 0.5 + (speaker.includesUser ? 0.125 : 0) : 0
                XCTAssertEqual(phone, [outgoing], "\(speaker)/\(listener)")
                XCTAssertEqual(monitor, [listening], "\(speaker)/\(listener)")
                XCTAssertEqual(try PCM24.decode(pcm), [model], "\(speaker)/\(listener)")
                cab_controls_set_send_muted(controls.pointer, true)
                let muted = cab_controls_snapshot(controls.pointer).routes
                cab_mix_mono(mic, agent, &phone, nil, 1, 1, 1, 1, muted)
                cab_mix_monitor(caller, agent, nil, &monitor, 1, 1, 1, muted)
                XCTAssertEqual(phone, [0]); XCTAssertEqual(monitor, [listening])
                let config = CallAudioConfiguration(virtualOutputUID: "unused", microphoneEnabled: speaker.includesUser, phoneRouting: policy)
                XCTAssertEqual(config.usesMicrophone, speaker.includesUser)
                XCTAssertEqual(config.needsListeningDevice, listener.includesUser)
            }
        }
    }
    func testBackgroundDefaultAndStopCannotBeUndoneByRouteChange() {
        let policy = PhoneRouting()
        XCTAssertEqual(policy.routes, [.agentToCaller, .callerToAgent])
        XCTAssertFalse(policy.routes.contains(.microphoneToCaller))
        let runtime = CallAudioRuntime()
        let revision = runtime.suspendRouting()
        runtime.stopAsync()
        XCTAssertThrowsError(try runtime.applyPhoneRouting(.init(speaker: .both, listener: .both), epoch: "new", expectedRevision: revision))
        runtime.stop()
    }
}
