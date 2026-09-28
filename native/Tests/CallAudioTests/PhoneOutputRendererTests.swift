import XCTest
import CallAudioDSP
@testable import CallAudio

final class PhoneOutputRendererTests: XCTestCase {
    private func render(_ renderer: inout OutputRenderer, microphone: [Float], agent: [Float]? = nil,
                        owner: [Float]? = nil, settings: CABControlsSnapshot) -> [Float] {
        let agent = agent ?? Array(repeating: 0, count: microphone.count)
        let owner = owner ?? Array(repeating: 0, count: microphone.count)
        var output = Array(repeating: Float(0), count: microphone.count)
        microphone.withUnsafeBufferPointer { mic in
            agent.withUnsafeBufferPointer { voice in
                owner.withUnsafeBufferPointer { privateVoice in
                    output.withUnsafeMutableBufferPointer { destination in
                        renderer.render(first: mic.baseAddress, second: voice.baseAddress,
                            third: privateVoice.baseAddress, output: destination.baseAddress!,
                            frames: mic.count, settings: settings)
                    }
                }
            }
        }
        return output
    }
    private func settings(microphone: Float = 1, agent: Float = 1, monitor: Float = 1,
                          routes: CallAudioRoutes = [.microphoneToCaller, .agentToCaller]) -> CABControlsSnapshot {
        .init(routes: routes.rawValue, mic_gain: microphone, agent_gain: agent, monitor_gain: monitor,
              monitor_agent_gain: agent, limiter_enabled: 1, limiter_ceiling: 0.98, limiter_release_ms: 80)
    }
    private func voicedBlock() -> [Float] {
        let raw: [Float] = (0..<256).map { frame in
            let phase = 2 * Double.pi * 190 * Double(frame) / 48000
            let envelope = 0.25 + 0.75 * sin(Double.pi * Double(frame) / 255)
            return Float(envelope * (sin(phase) + 0.3 * sin(2 * phase) + 0.12 * sin(3 * phase)))
        }
        let peak = raw.map { abs($0) }.max()!
        return raw.map { $0 * (0.509 / peak) }
    }

    func testPhoneCallbackRendererPreservesBoostedVoiceShapeInsteadOfClipping() {
        // These approximate the measured microphone peak and gain from the
        // muffled-call report. Exercise the same default Phone renderer used
        // by OutputIO, rather than invoking the limiter in isolation.
        var renderer = OutputRenderer(kind: .phone, sampleRate: 48000)
        let voice = voicedBlock()
        let output = render(&renderer, microphone: voice,
            settings: settings(microphone: 2.9570112, agent: 0, routes: .microphoneToCaller))
        XCTAssertLessThanOrEqual(output.map { abs($0) }.max()!, 0.980001)
        XCTAssertFalse(output.contains { abs($0) == 1 })
        let expectedGain: Float = 0.98 / 0.509
        let largestShapeError = zip(voice, output).map { abs($1 - $0 * expectedGain) }.max()!
        XCTAssertLessThan(largestShapeError, 0.000002)
    }

    func testPhoneCallbackCombinesVoiceAndMicrophoneBeforeLimiting() {
        var renderer = OutputRenderer(kind: .phone, sampleRate: 48000)
        let microphone: [Float] = [0.1, 0.4, 0.2, -0.4, -0.2]
        let agent: [Float] = [0.2, 0.45, 0.1, -0.45, -0.1]
        let output = render(&renderer, microphone: microphone, agent: agent,
            settings: settings(microphone: 3, agent: 1))
        let peakBeforeLimiting: Float = 0.4 * 3 + 0.45
        for i in microphone.indices {
            XCTAssertEqual(output[i], (microphone[i] * 3 + agent[i]) * 0.98 / peakBeforeLimiting,
                           accuracy: 0.000002)
        }
    }
    func testLiveLimiterControlsAndIndependentMonitorGainReachProductionRenderer() {
        let controls = AudioControls()
        cab_controls_set_send_muted(controls.pointer, false)
        cab_controls_set_routes(controls.pointer, CallAudioRoutes.all.rawValue)
        var tuning = CallAudioTuning()
        tuning[.microphoneToCaller] = 3
        tuning[.agentToCaller] = 0.5
        tuning[.agentToUser] = 2
        tuning[.callerToUser] = 0.25
        tuning.limiterCeiling = 0.5
        tuning.apply(to: controls.pointer)
        var phone = OutputRenderer(kind: .phone, sampleRate: 48000)
        var monitor = OutputRenderer(kind: .monitor, sampleRate: 48000)
        var snapshot = cab_controls_snapshot(controls.pointer)
        XCTAssertEqual(render(&phone, microphone: [0.2], agent: [0.2], settings: snapshot)[0], 0.5, accuracy: 0.00001)
        XCTAssertEqual(render(&monitor, microphone: [0.2], agent: [0.2], settings: snapshot)[0], 0.45, accuracy: 0.00001)
        tuning.limiterEnabled = false; tuning.apply(to: controls.pointer)
        snapshot = cab_controls_snapshot(controls.pointer)
        XCTAssertEqual(render(&phone, microphone: [0.2], agent: [0.2], settings: snapshot)[0], 0.7, accuracy: 0.00001)
        XCTAssertEqual(render(&phone, microphone: [0.9], agent: [0.2], settings: snapshot)[0], 1)
        tuning.limiterEnabled = true; tuning.limiterCeiling = 0.98; tuning.apply(to: controls.pointer)
        XCTAssertEqual(render(&phone, microphone: [0.1], settings: cab_controls_snapshot(controls.pointer))[0], 0.3, accuracy: 0.00001)
    }

    func testLiveReleaseSettingChangesRecoverySpeedWithoutExceedingCeiling() {
        func recovered(_ milliseconds: Float) -> Float {
            var renderer = OutputRenderer(kind: .phone, sampleRate: 48000)
            var config = settings(microphone: 4, agent: 0, routes: .microphoneToCaller)
            config.limiter_release_ms = milliseconds
            _ = render(&renderer, microphone: [0.8], settings: config)
            let quiet = render(&renderer, microphone: Array(repeating: 0.1, count: 4800), settings: config)
            XCTAssertLessThanOrEqual(quiet.max()!, 0.4)
            return quiet.last!
        }
        XCTAssertGreaterThan(recovered(10), recovered(1000) * 2)
    }

    func testUnityBelowCeilingIsTransparentAndCallerMixExcludesPrivateMonitor() {
        var renderer = OutputRenderer(kind: .phone, sampleRate: 48000)
        let output = render(&renderer, microphone: [0.1, -0.2, 0.4], agent: [0.2, 0.1, -0.15],
            owner: [0.9, 0.9, 0.9], settings: settings(routes: .all))
        let expected: [Float] = [0.3, -0.1, 0.25]
        for i in expected.indices { XCTAssertEqual(output[i], expected[i], accuracy: 0.000001) }
    }

    func testLimiterRecoversAcrossCallbackBlocksAndMuteResetsAttenuation() {
        var renderer = OutputRenderer(kind: .phone, sampleRate: 48000)
        let boosted = settings(microphone: 4, agent: 0, routes: .microphoneToCaller)
        let attack = render(&renderer, microphone: Array(repeating: 0.5, count: 512), settings: boosted)
        XCTAssertEqual(attack[0], 0.98, accuracy: 0.000001)
        let quiet = Array(repeating: Float(0.1), count: 512)
        let firstRecovery = render(&renderer, microphone: quiet, settings: boosted)
        XCTAssertLessThan(firstRecovery[0], 0.3)
        var previous = firstRecovery.last!
        for _ in 0..<64 {
            let next = render(&renderer, microphone: quiet, settings: boosted)
            XCTAssertGreaterThanOrEqual(next.first!, previous)
            XCTAssertLessThanOrEqual(next.last!, 0.4)
            previous = next.last!
        }
        XCTAssertEqual(previous, 0.4, accuracy: 0.0001)
        _ = render(&renderer, microphone: Array(repeating: 0.5, count: 512), settings: boosted)
        let muted = render(&renderer, microphone: quiet, settings: settings(routes: []))
        XCTAssertEqual(muted, Array(repeating: 0, count: 512))
        let resumed = render(&renderer, microphone: quiet, settings: settings(routes: .microphoneToCaller))
        XCTAssertEqual(resumed, quiet)
    }

    func testSendMuteAndCancellationKeepMonitorIsolationAndSourceGates() {
        var phone = OutputRenderer(kind: .phone, sampleRate: 48000)
        var monitor = OutputRenderer(kind: .monitor, sampleRate: 48000)
        let controls = AudioControls()
        cab_controls_set_gains(controls.pointer, 1, 1, 0.5)
        cab_controls_set_routes(controls.pointer, CallAudioRoutes.all.rawValue)
        let initial = cab_controls_snapshot(controls.pointer)
        XCTAssertEqual(render(&phone, microphone: [0.2], agent: [0.3], owner: [0.1], settings: initial), [0])
        XCTAssertEqual(render(&monitor, microphone: [0.2], agent: [0.3], owner: [0.1], settings: initial), [0.5])
        cab_controls_set_send_muted(controls.pointer, false)
        XCTAssertEqual(render(&phone, microphone: [0.2], agent: [0.3], owner: [0.9],
            settings: cab_controls_snapshot(controls.pointer)), [0.5])
        cab_controls_set_routes(controls.pointer, CallAudioRoutes.microphoneToCaller.rawValue)
        XCTAssertEqual(render(&phone, microphone: [0.2], agent: [0.3],
            settings: cab_controls_snapshot(controls.pointer)), [0.2])
        cab_controls_set_routes(controls.pointer, CallAudioRoutes.agentToCaller.rawValue)
        XCTAssertEqual(render(&phone, microphone: [0.2], agent: [0.3],
            settings: cab_controls_snapshot(controls.pointer)), [0.3])
        cab_controls_cancel(controls.pointer)
        XCTAssertEqual(render(&phone, microphone: [0.2], agent: [0.3],
            settings: cab_controls_snapshot(controls.pointer)), [0])
        XCTAssertEqual(render(&monitor, microphone: [0.2], agent: [0.3], owner: [0.1],
            settings: cab_controls_snapshot(controls.pointer)), [0])
    }
}
